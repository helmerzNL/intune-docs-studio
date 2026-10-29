<#
    In-memory CIS build-kit archive reading and conversion. Requires
    BaselinePacks.ps1, AssessmentCollection.ps1 and AssessmentSettings.ps1.

    Policy values come from ConvertFrom-IdsPackJsonElement. Nothing is written
    here. Generated packs are deterministic for the same archive, so importing
    it again is idempotent.
#>

function Get-IdsBuildKitSha256 {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Write-IdsBuildKitJsonValue {
    param([Text.Json.Utf8JsonWriter]$Writer, $Value)
    if ($null -eq $Value) { $Writer.WriteNullValue(); return }
    if ($Value -is [bool]) { $Writer.WriteBooleanValue($Value); return }
    if ($Value -is [string]) { $Writer.WriteStringValue([string]$Value); return }
    if ($Value -is [decimal]) { $Writer.WriteNumberValue([decimal]$Value); return }
    if ($Value -is [double] -or $Value -is [single]) { $Writer.WriteNumberValue([double]$Value); return }
    if ($Value -is [uint64]) { $Writer.WriteNumberValue([uint64]$Value); return }
    if ($Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64]) {
        $Writer.WriteNumberValue([long]$Value)
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        $Writer.WriteStartObject()
        foreach ($pair in $Value.GetEnumerator()) {
            $Writer.WritePropertyName([string]$pair.Key)
            Write-IdsBuildKitJsonValue $Writer $pair.Value
        }
        $Writer.WriteEndObject()
        return
    }
    if ($Value -is [Collections.IList]) {
        $Writer.WriteStartArray()
        foreach ($item in $Value) { Write-IdsBuildKitJsonValue $Writer $item }
        $Writer.WriteEndArray()
        return
    }
    throw "Unsupported generated pack value type: $($Value.GetType().FullName)."
}

function ConvertTo-IdsBuildKitJsonBytes {
    param($Value)
    $options = [Text.Json.JsonWriterOptions]::new()
    $options.Indented = $true
    $stream = [IO.MemoryStream]::new()
    try {
        $writer = [Text.Json.Utf8JsonWriter]::new($stream, $options)
        try {
            Write-IdsBuildKitJsonValue $writer $Value
            $writer.Flush()
        } finally { $writer.Dispose() }
        return ,($stream.ToArray())
    } finally { $stream.Dispose() }
}

function Add-IdsBuildKitSettingScan {
    param($Node, $Scan)
    if ($Node -is [Collections.IList]) {
        foreach ($item in $Node) { Add-IdsBuildKitSettingScan $item $Scan }
        return
    }
    if ($Node -isnot [Collections.IDictionary]) { return }
    $id = $Node['settingDefinitionId']
    if ($id -is [string] -and -not [string]::IsNullOrWhiteSpace($id)) {
        [void]$Scan.ids.Add($id)
        $count = 0
        [void]$Scan.counts.TryGetValue($id, [ref]$count)
        $Scan.counts[$id] = $count + 1
    }
    # A nested default must exclude its parent choice too.
    if ((Get-IdsAssessmentMember $Node['settingValueTemplateReference'] 'useTemplateDefault') -eq $true) {
        $Scan.templateDefault = $true
    }
    # Enumerate pairs: member access on a dictionary can resolve to a key.
    foreach ($pair in $Node.GetEnumerator()) { Add-IdsBuildKitSettingScan $pair.Value $Scan }
}

function Get-IdsBuildKitValueKey {
    param([string]$ValueType, $Value)
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        $text = if ($item -is [bool]) {
            if ($item) { 'true' } else { 'false' }
        } elseif ($item -is [string]) {
            $item
        } elseif ($item -is [decimal]) {
            ConvertTo-IdsPackNumberKey ($item.ToString('G29', [Globalization.CultureInfo]::InvariantCulture))
        } elseif ($item -is [double] -or $item -is [single]) {
            ConvertTo-IdsPackNumberKey ($item.ToString('R', [Globalization.CultureInfo]::InvariantCulture))
        } else {
            ConvertTo-IdsPackNumberKey ([Convert]::ToString($item, [Globalization.CultureInfo]::InvariantCulture))
        }
        $parts.Add("$($text.Length):$text")
    }
    $keys = $parts.ToArray()
    if ($ValueType -cin @('stringSet', 'numberSet')) { [Array]::Sort($keys, [StringComparer]::Ordinal) }
    return "$ValueType|" + ($keys -join '|')
}

function Get-IdsBuildKitProfile {
    param([string]$Name)
    $levels = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($Name, '(?<![\p{L}\p{N}])(L1|L2|BL|NG)(?![\p{L}\p{N}])')) {
        [void]$levels.Add($match.Groups[1].Value)
    }
    foreach ($match in [regex]::Matches($Name, '(?<![\p{L}\p{N}])level ([12])(?![\p{L}\p{N}])', 'IgnoreCase,CultureInvariant')) {
        [void]$levels.Add("L$($match.Groups[1].Value)")
    }
    $level = if ($levels.Count -eq 1) { @($levels)[0] } else { $null }
    switch -CaseSensitive ($level) {
        'L1' { return [pscustomobject]@{ label = 'Level 1 (L1)'; slug = 'l1' } }
        'L2' { return [pscustomobject]@{ label = 'Level 2 (L2)'; slug = 'l2' } }
        'BL' { return [pscustomobject]@{ label = 'BitLocker (BL)'; slug = 'bl' } }
        'NG' { return [pscustomobject]@{ label = 'Next Generation Windows Security (NG)'; slug = 'ng' } }
    }
    return [pscustomobject]@{ label = 'Unclassified build kit policies'; slug = 'build-kit' }
}

function Get-IdsBuildKitPolicyName {
    param($Policy, [string]$Entry)
    foreach ($field in @('name', 'displayName')) {
        $value = Get-IdsAssessmentMember $Policy $field
        if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    $file = @($Entry -split '[/\\]')[-1] -replace '(?i)\.json\z', ''
    if ([string]::IsNullOrWhiteSpace($file)) { return $Entry }
    return $file
}

function Get-IdsBuildKitVersions {
    param([string[]]$Texts)
    $versions = [Collections.Generic.List[string]]::new()
    foreach ($text in $Texts) {
        # Retain four-part versions so they prevent a false three-part match or fallback.
        foreach ($match in [regex]::Matches($text, '(?<![A-Za-z0-9])v[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)*')) {
            if (-not $versions.Contains($match.Value)) { $versions.Add($match.Value) }
        }
    }
    return ,($versions.ToArray())
}

function ConvertTo-IdsBuildKitPacks {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Policies,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ArchiveSha256)
    if ($ArchiveSha256 -cnotmatch '\A[0-9a-f]{64}\z') { throw 'ArchiveSha256 must be 64 lowercase hexadecimal characters.' }
    $skipped = [Collections.Generic.List[object]]::new()
    $groups = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($item in $Policies) {
        $entry = [string]$item.entry
        $policy = $item.policy
        $name = Get-IdsBuildKitPolicyName $policy $entry
        $platform = Get-IdsAssessmentPlatform $policy $null
        if (-not $platform) {
            $skipped.Add([pscustomobject]@{ entry = $entry; reason = "Policy '$name' targets an unsupported or combined platform." })
            continue
        }
        $settings = Get-IdsAssessmentMember $policy 'settings'
        if ($settings -isnot [Collections.IList] -or $settings.Count -eq 0) {
            $skipped.Add([pscustomobject]@{ entry = $entry; reason = "Policy '$name' contains no settings." })
            continue
        }
        $definitions = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $titles = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        foreach ($setting in $settings) {
            foreach ($definition in (Get-IdsAssessmentMember $setting 'settingDefinitions')) {
                $definitionId = Get-IdsAssessmentMember $definition 'id'
                if ($definitionId -isnot [string]) { continue }
                if (-not $definitions.ContainsKey($definitionId)) {
                    $definitions[$definitionId] = [Collections.Generic.List[object]]::new()
                }
                $definitions[$definitionId].Add($definition)
                $displayName = Get-IdsAssessmentMember $definition 'displayName'
                if (-not $titles.ContainsKey($definitionId) -and $displayName -is [string] -and
                    -not [string]::IsNullOrWhiteSpace($displayName)) {
                    $titles[$definitionId] = $displayName
                }
            }
        }
        $state = @{
            policy = [pscustomobject]@{ key = "$entry/$name"; family = 'settingsCatalog'; settingsComplete = $true }
            observations = [Collections.Generic.List[object]]::new()
            issues = [Collections.Generic.List[object]]::new()
        }
        $counters = @{}
        $counts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
        $kept = [Collections.Generic.List[object]]::new()
        foreach ($setting in $settings) {
            $instance = Get-IdsAssessmentMember $setting 'settingInstance'
            $topId = Get-IdsAssessmentMember $instance 'settingDefinitionId'
            $label = if ($topId -is [string] -and -not [string]::IsNullOrWhiteSpace($topId)) { $topId } else { '(unnamed setting)' }
            $scan = @{
                ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                counts = $counts; templateDefault = $false
            }
            Add-IdsBuildKitSettingScan $instance $scan
            if ($scan.templateDefault) {
                $skipped.Add([pscustomobject]@{ entry = $entry
                    reason = "Setting '$label' in policy '$name' uses a template default value and was not converted." })
                continue
            }
            # Only relevant definitions are needed by the normalizer.
            $subset = [Collections.Generic.List[object]]::new()
            foreach ($id in $scan.ids) {
                if ($definitions.ContainsKey($id)) { $subset.AddRange($definitions[$id]) }
            }
            $start = $state.observations.Count
            ConvertTo-IdsCatalogObservations $state $instance $subset.ToArray() '' $counters
            for ($index = $start; $index -lt $state.observations.Count; $index++) {
                $observation = $state.observations[$index]
                $problem = if ($observation.secret) { 'is secret' }
                elseif (-not $observation.supported) { 'has an unsupported shape or value type' }
                elseif (-not $observation.configured -or -not $observation.valueType) { 'has no configured value' }
                else { $null }
                if (-not $problem) { $kept.Add($observation); continue }
                $settingLabel = if ($observation.settingId -is [string] -and
                    -not [string]::IsNullOrWhiteSpace($observation.settingId)) { $observation.settingId } else { '(unnamed setting)' }
                $skipped.Add([pscustomobject]@{ entry = $entry
                    reason = "Setting '$settingLabel' in policy '$name' $problem and was not converted." })
            }
        }
        $level = Get-IdsBuildKitProfile $name
        $packId = "cis.$($platform.ToLowerInvariant()).$($level.slug)"
        if (-not $groups.ContainsKey($packId)) {
            $groups[$packId] = [pscustomobject]@{
                platform = $platform; profile = $level.label; members = [Collections.Generic.List[object]]::new()
            }
        }
        $group = $groups[$packId]
        $group.members.Add([pscustomobject]@{
            index = $group.members.Count; entry = $entry; name = $name
            lastWriteTime = ([DateTimeOffset]$item.lastWriteTime).DateTime
            observations = $kept; titles = $titles; counts = $counts
        })
    }

    $packs = [Collections.Generic.List[byte[]]]::new()
    $packIds = [string[]]@($groups.Keys)
    [Array]::Sort($packIds, [StringComparer]::Ordinal)
    foreach ($packId in $packIds) {
        $group = $groups[$packId]
        $candidates = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($member in $group.members) {
            # Count raw occurrences, including skipped values and entire skipped settings.
            foreach ($pair in $member.counts.GetEnumerator()) {
                $id = $pair.Key
                if ($pair.Value -le 1 -or -not $excluded.Add($id)) { continue }
                [void]$candidates.Remove($id)
                $skipped.Add([pscustomobject]@{ entry = $member.entry
                    reason = "Setting '$id' occurs more than once in policy '$($member.name)', so it was skipped for pack '$packId'." })
            }
            foreach ($observation in $member.observations) {
                $id = $observation.settingId
                if ($excluded.Contains($id)) { continue }
                $key = Get-IdsBuildKitValueKey $observation.valueType $observation.value
                if (-not $candidates.ContainsKey($id)) {
                    $candidate = [pscustomobject]@{ key = $key; observation = $observation; members = [Collections.Generic.List[object]]::new() }
                    $candidate.members.Add($member)
                    $candidates[$id] = $candidate
                } elseif (-not [StringComparer]::Ordinal.Equals($candidates[$id].key, $key)) {
                    $first = $candidates[$id].members[0]
                    [void]$excluded.Add($id)
                    [void]$candidates.Remove($id)
                    $skipped.Add([pscustomobject]@{ entry = $member.entry
                        reason = "Setting '$id' has different values in policies '$($first.name)' (archive entry '$($first.entry)') " +
                            "and '$($member.name)' (archive entry '$($member.entry)'), so it was skipped for pack '$packId'." })
                } else {
                    $candidates[$id].members.Add($member)
                }
            }
        }
        if ($candidates.get_Count() -eq 0) { continue }

        $controlIds = [string[]]@($candidates.get_Keys())
        [Array]::Sort($controlIds, [StringComparer]::Ordinal)
        $used = [Collections.Generic.HashSet[int]]::new()
        $controls = [Collections.Generic.List[object]]::new()
        foreach ($id in $controlIds) {
            $candidate = $candidates[$id]
            $references = [Collections.Generic.List[string]]::new()
            foreach ($member in $candidate.members) {
                [void]$used.Add($member.index)
                $reference = "CIS build kit policy '$($member.name)' (archive entry '$($member.entry)')"
                if (-not $references.Contains($reference)) { $references.Add($reference) }
            }
            $reference = if ($references.Count -gt 5) {
                ($references.GetRange(0, 5) -join '; ') + "; and $($references.Count - 5) more"
            } else { $references -join '; ' }
            $title = $id
            if ($candidate.members[0].titles.ContainsKey($id)) { $title = $candidate.members[0].titles[$id] }
            $valueType = $candidate.observation.valueType
            $controls.Add([ordered]@{
                id = $id; title = $title; sourceIds = @('cis-build-kit'); reference = $reference
                applicability = [ordered]@{ osMin = $null; osMax = $null; enrollmentModes = @() }
                manualReason = $null
                mappings = @([ordered]@{
                    family = 'settingsCatalog'; policyTypes = @('deviceManagementConfigurationPolicy')
                    settingId = $id; property = $null; instancePath = $null; valueType = $valueType
                    operator = $(if ($valueType -cin @('stringSet', 'numberSet')) { 'setEquals' } else { 'eq' })
                    expected = $candidate.observation.value; caseSensitive = $true
                })
            })
        }

        $newest = $null
        $names = [Collections.Generic.List[string]]::new()
        $entries = [Collections.Generic.List[string]]::new()
        foreach ($member in $group.members) {
            if (-not $used.Contains($member.index)) { continue }
            if ($null -eq $newest -or $member.lastWriteTime -gt $newest) { $newest = $member.lastWriteTime }
            $names.Add($member.name)
            $entries.Add($member.entry)
        }
        $versions = Get-IdsBuildKitVersions $names.ToArray()
        if ($versions.Count -eq 0) { $versions = Get-IdsBuildKitVersions $entries.ToArray() }
        $frameworkVersion = if ($versions.Count -eq 1 -and $versions[0] -cmatch '\Av[0-9]+\.[0-9]+\.[0-9]+\z') {
            $versions[0]
        } else { 'Unknown (customer-supplied build kit)' }
        # Use the archive's stored wall-clock date, independent of local time zone.
        $retrievedOn = $newest.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $pack = [ordered]@{
            schemaVersion = 1L; id = $packId; version = '1.0.0'; framework = 'CIS'
            frameworkVersion = $frameworkVersion; classification = 'baseline'
            platform = $group.platform; profile = $group.profile
            sourceRevision = "CIS build kit archive SHA-256 $ArchiveSha256"
            sources = @([ordered]@{
                id = 'cis-build-kit'; url = 'https://workbench.cisecurity.org/'
                revision = "Archive SHA-256 $ArchiveSha256"; retrievedOn = $retrievedOn
            })
            coverage = [ordered]@{ inventory = 'partial'; totalSourceControls = $null }
            controls = $controls.ToArray()
        }
        $pack.version = '1.0.0+' + (Get-IdsBuildKitSha256 (ConvertTo-IdsBuildKitJsonBytes $pack)).Substring(0, 12)
        $bytes = ConvertTo-IdsBuildKitJsonBytes $pack
        if ($bytes.Length -gt 10MB) {
            $skipped.Add([pscustomobject]@{ entry = $packId; reason = "Generated pack '$packId' exceeds the 10 MiB pack limit." })
            continue
        }
        try { [void](Read-IdsBaselinePack -Bytes $bytes) } catch {
            $skipped.Add([pscustomobject]@{ entry = $packId; reason = "Generated pack '$packId' is invalid: $($_.Exception.Message)" })
            continue
        }
        $packs.Add($bytes)
    }
    return [pscustomobject]@{ packs = $packs.ToArray(); skipped = $skipped.ToArray() }
}

function Read-IdsBaselineArchiveEntry {
    param($Entry, $Budget)
    # Bound actual decompression even when the declared size is false.
    # Bytes from entries that are later skipped still consume the budget.
    $limit = 10MB + 1
    $buffer = [byte[]]::new(81920)
    $content = [IO.MemoryStream]::new()
    $source = $null
    try {
        $source = $Entry.Open()
        while ($content.Length -lt $limit -and $Budget.read -le 64MB) {
            $count = $source.Read($buffer, 0, [int][Math]::Min([long]$buffer.Length, $limit - $content.Length))
            if ($count -le 0) { break }
            $Budget.read += $count
            $content.Write($buffer, 0, $count)
        }
        return ,($content.ToArray())
    } finally {
        if ($source) { $source.Dispose() }
        $content.Dispose()
    }
}

function ConvertFrom-IdsBaselineArchiveText {
    param([byte[]]$Bytes)
    # UTF-32 LE shares the UTF-16 LE prefix, but is not a supported encoding.
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) {
        throw [Text.DecoderFallbackException]::new('UTF-32 text is not supported.')
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, 3, $Bytes.Length - 3)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.UnicodeEncoding]::new($false, $false, $true).GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [Text.UnicodeEncoding]::new($true, $false, $true).GetString($Bytes, 2, $Bytes.Length - 2)
    }
    return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
}

function Get-IdsBaselineArchivePolicies {
    param($Value)
    if ($Value -is [Collections.IDictionary] -and $Value.Contains('settings')) { return ,@(, $Value) }
    $list = $Value
    if ($Value -is [Collections.IDictionary] -and $Value.Contains('value')) { $list = $Value['value'] }
    if ($list -isnot [Collections.IList] -or $list.Count -eq 0) { return $null }
    foreach ($item in $list) {
        if ($item -isnot [Collections.IDictionary] -or -not $item.Contains('settings')) { return $null }
    }
    return ,@($list)
}

function ConvertFrom-IdsBaselineArchive {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    Add-Type -AssemblyName System.IO.Compression
    $sha256 = Get-IdsBuildKitSha256 $Bytes
    $packs = [Collections.Generic.List[byte[]]]::new()
    $skipped = [Collections.Generic.List[object]]::new()
    $policies = [Collections.Generic.List[object]]::new()
    $ignored = 0
    $budget = @{ read = 0L }
    $unreadable = 'Could not be read (encrypted, corrupt or unsupported compression).'
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 64
    $stream = [IO.MemoryStream]::new($Bytes, $false)
    $archive = $null
    try {
        try {
            $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
            # Invoke the getter explicitly: PowerShell property access can
            # suppress its central-directory validation exception as $null.
            $entries = @($archive.get_Entries())
        } catch {
            # ZipArchive reports damage as InvalidDataException, which the API maps to 413.
            throw [ArgumentException]::new('The file is not a valid ZIP archive.')
        }
        if ($entries.Count -gt 1000) { throw [ArgumentException]::new('Archive entry limit exceeded (1,000 entries).') }
        $jsonCount = 0
        foreach ($entry in $entries) {
            $name = $entry.FullName
            if ($name.StartsWith('/') -or $name.StartsWith('\') -or $name.Contains(':') -or
                (($name -split '[/\\]') -contains '..')) {
                throw [ArgumentException]::new("Archive entry names must be relative without ':' or '..' segments.")
            }
            if ($name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { $jsonCount++ }
        }
        if ($jsonCount -gt 500) { throw [ArgumentException]::new('Archive JSON entry limit exceeded (500 entries).') }

        foreach ($entry in $entries) {
            $name = $entry.FullName
            if ($name.EndsWith('/') -or $name.EndsWith('\')) { continue }
            if ($name.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'Nested ZIP archives are not opened; extract and upload the inner ZIP.' })
                continue
            }
            if (-not $name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { $ignored++; continue }
            $encrypted = $entry.PSObject.Properties['IsEncrypted']
            if ($encrypted -and $encrypted.Value) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = $unreadable })
                continue
            }
            if ($entry.Length -gt 10MB) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'JSON entry exceeds the 10 MiB limit.' })
                continue
            }
            $content = $null
            try { $content = Read-IdsBaselineArchiveEntry $entry $budget }
            catch [IO.InvalidDataException], [IO.IOException], [NotSupportedException], [InvalidOperationException] { $content = $null }
            # Outside the entry catch: the budget fails the whole request.
            if ($budget.read -gt 64MB) { throw [IO.InvalidDataException]::new('Archive JSON read limit exceeded (64 MiB).') }
            if ($null -eq $content) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = $unreadable })
                continue
            }
            if ($content.Length -gt 10MB) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'JSON entry exceeds the 10 MiB limit.' })
                continue
            }
            if ($content.Length -ne $entry.Length) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = $unreadable })
                continue
            }
            try { $text = ConvertFrom-IdsBaselineArchiveText $content } catch {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'Not valid UTF-8 or UTF-16 text.' })
                continue
            }
            try { $document = [Text.Json.JsonDocument]::Parse($text, $options) } catch {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'Invalid JSON or nesting deeper than 64 levels.' })
                continue
            }
            try { $value = ConvertFrom-IdsPackJsonElement $document.RootElement } catch {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = "Invalid JSON: $($_.Exception.Message)" })
                continue
            } finally { $document.Dispose() }
            if ($value -is [Collections.IDictionary] -and $value.Contains('schemaVersion')) {
                $packBytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
                try { [void](Read-IdsBaselinePack -Bytes $packBytes) } catch {
                    $skipped.Add([pscustomobject]@{ entry = $name; reason = "Invalid rule pack: $($_.Exception.Message)" })
                    continue
                }
                $packs.Add($packBytes)
                continue
            }
            $found = Get-IdsBaselineArchivePolicies $value
            if ($null -eq $found) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = 'Not a Settings Catalog policy or rule pack.' })
                continue
            }
            foreach ($policy in $found) {
                $policies.Add([pscustomobject]@{ entry = $name; policy = $policy; lastWriteTime = $entry.LastWriteTime })
            }
        }
    } finally {
        if ($archive) { $archive.Dispose() }
        $stream.Dispose()
    }
    $converted = ConvertTo-IdsBuildKitPacks -Policies $policies.ToArray() -ArchiveSha256 $sha256
    foreach ($pack in $converted.packs) { $packs.Add($pack) }
    foreach ($item in $converted.skipped) { $skipped.Add($item) }
    return [pscustomobject]@{ packs = $packs.ToArray(); skipped = $skipped.ToArray(); ignored = $ignored; sha256 = $sha256 }
}
