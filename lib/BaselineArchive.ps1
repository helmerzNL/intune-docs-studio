. (Join-Path $PSScriptRoot 'Localization.ps1')

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
    throw (Get-IdsText -Key 'text.unsupported_generated_pack_value_type_arg0' -Arguments @{ arg0 = ($Value.GetType().FullName) })
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
    if ($ArchiveSha256 -cnotmatch '\A[0-9a-f]{64}\z') { throw (Get-IdsText -Key 'text.archivesha256_must_be_64_lowercase_hexadecimal_characters') }
    $skipped = [Collections.Generic.List[object]]::new()
    $groups = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($item in $Policies) {
        $entry = [string]$item.entry
        $policy = $item.policy
        $name = Get-IdsBuildKitPolicyName $policy $entry
        $platform = Get-IdsAssessmentPlatform $policy $null
        if (-not $platform) {
            $skipped.Add([pscustomobject]@{ entry = $entry; reason = (Get-IdsText -Key 'text.policy_arg0_targets_an_unsupported_or_combined_platform' -Arguments @{ arg0 = ($name) }) })
            continue
        }
        $settings = Get-IdsAssessmentMember $policy 'settings'
        if ($settings -isnot [Collections.IList] -or $settings.Count -eq 0) {
            $skipped.Add([pscustomobject]@{ entry = $entry; reason = (Get-IdsText -Key 'text.policy_arg0_contains_no_settings' -Arguments @{ arg0 = ($name) }) })
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
            $label = if ($topId -is [string] -and -not [string]::IsNullOrWhiteSpace($topId)) { $topId } else { (Get-IdsText -Key 'text.unnamed_setting') }
            $scan = @{
                ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                counts = $counts; templateDefault = $false
            }
            Add-IdsBuildKitSettingScan $instance $scan
            if ($scan.templateDefault) {
                $skipped.Add([pscustomobject]@{ entry = $entry
                    reason = (Get-IdsText -Key 'text.setting_arg0_in_policy_arg1_uses_a_template_default_value_and_was_not_converted' -Arguments @{ arg0 = ($label); arg1 = ($name) }) })
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
                $problem = if ($observation.secret) { (Get-IdsText -Key 'text.is_secret') }
                elseif (-not $observation.supported) { (Get-IdsText -Key 'text.has_an_unsupported_shape_or_value_type') }
                elseif (-not $observation.configured -or -not $observation.valueType) { (Get-IdsText -Key 'text.has_no_configured_value') }
                else { $null }
                if (-not $problem) { $kept.Add($observation); continue }
                $settingLabel = if ($observation.settingId -is [string] -and
                    -not [string]::IsNullOrWhiteSpace($observation.settingId)) { $observation.settingId } else { (Get-IdsText -Key 'text.unnamed_setting') }
                $skipped.Add([pscustomobject]@{ entry = $entry
                    reason = (Get-IdsText -Key 'text.setting_arg0_in_policy_arg1_arg2_and_was_not_converted' -Arguments @{ arg0 = ($settingLabel); arg1 = ($name); arg2 = ($problem) }) })
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
                    reason = (Get-IdsText -Key 'text.setting_arg0_occurs_more_than_once_in_policy_arg1_so_it_was_skipped_for_pack_arg2' -Arguments @{ arg0 = ($id); arg1 = ($member.name); arg2 = ($packId) }) })
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
                        reason = (Get-IdsText 'import.mapping_conflict' -Arguments @{
                            setting = $id; firstPolicy = $first.name; firstEntry = $first.entry
                            secondPolicy = $member.name; secondEntry = $member.entry; pack = $packId
                        }) })
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
            $skipped.Add([pscustomobject]@{ entry = $packId; reason = (Get-IdsText -Key 'text.generated_pack_arg0_exceeds_the_10_mib_pack_limit' -Arguments @{ arg0 = ($packId) }) })
            continue
        }
        try { [void](Read-IdsBaselinePack -Bytes $bytes) } catch {
            $skipped.Add([pscustomobject]@{ entry = $packId; reason = (Get-IdsText -Key 'text.generated_pack_arg0_is_invalid_arg1' -Arguments @{ arg0 = ($packId); arg1 = ($_.Exception.Message) }) })
            continue
        }
        $packs.Add($bytes)
    }
    return [pscustomobject]@{ packs = $packs.ToArray(); skipped = $skipped.ToArray() }
}

function Initialize-IdsBaselineArchiveReader {
    if ('Ids.BaselineZipReader' -as [type]) { return }
    # ZipArchiveEntry.Open() can clamp deflate output to an untrusted declared
    # length and does not check CRC. Read bounded raw spans instead; keep the
    # checksum loop in managed code rather than PowerShell's per-byte pipeline.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;

namespace Ids {
    public sealed class BaselineZipEntry {
        public ulong Length, CompressedLength, LocalOffset, DirectoryOffset, NameOffset;
        public uint Crc;
        public ushort Flags, Method, NameLength;
        public bool Valid = true;
    }

    public static class BaselineZipReader {
        const long EntryLimit = 10 * 1024 * 1024, ArchiveLimit = 64 * 1024 * 1024;
        static readonly uint[] CrcTable = CreateCrcTable();

        static InvalidDataException Invalid() { return new InvalidDataException("Invalid ZIP metadata or entry integrity."); }
        static void Range(ulong offset, ulong size, ulong limit) {
            if (offset > limit || size > limit - offset) throw Invalid();
        }
        static ushort U16(byte[] b, ulong p) {
            Range(p, 2, (ulong)b.Length);
            return (ushort)(b[(int)p] | b[(int)p + 1] << 8);
        }
        static uint U32(byte[] b, ulong p) {
            Range(p, 4, (ulong)b.Length);
            return (uint)(b[(int)p] | b[(int)p + 1] << 8 | b[(int)p + 2] << 16 | b[(int)p + 3] << 24);
        }
        static ulong U64(byte[] b, ulong p) {
            return U32(b, p) | ((ulong)U32(b, p + 4) << 32);
        }

        static void Extra64(byte[] b, ulong start, ushort length, ref ulong size,
                            ref ulong packed, ref ulong local, ref ulong disk) {
            ulong end = start + length;
            Range(start, length, (ulong)b.Length);
            bool needed = size == uint.MaxValue || packed == uint.MaxValue ||
                          local == uint.MaxValue || disk == ushort.MaxValue;
            bool found = false;
            for (ulong p = start; p < end;) {
                Range(p, 4, end);
                ushort tag = U16(b, p), count = U16(b, p + 2);
                p += 4;
                Range(p, count, end);
                ulong next = p + count;
                if (tag == 1) {
                    if (found) throw Invalid();
                    found = true;
                    if (size == uint.MaxValue) { Range(p, 8, next); size = U64(b, p); p += 8; }
                    if (packed == uint.MaxValue) { Range(p, 8, next); packed = U64(b, p); p += 8; }
                    if (local == uint.MaxValue) { Range(p, 8, next); local = U64(b, p); p += 8; }
                    if (disk == ushort.MaxValue) { Range(p, 4, next); disk = U32(b, p); }
                }
                p = next;
            }
            if (needed && !found) throw Invalid();
        }

        public static BaselineZipEntry[] ReadDirectory(byte[] b, int expectedCount) {
            if (expectedCount < 0 || expectedCount > 1000) throw Invalid();
            long endRecord = -1;
            // The only scan is the format's bounded EOCD/comment window.
            for (int p = b.Length - 22; p >= Math.Max(0, b.Length - 65557); p--) {
                if (U32(b, (ulong)p) == 0x06054b50 &&
                    (ulong)p + 22 + U16(b, (ulong)p + 20) == (ulong)b.Length) {
                    endRecord = p; break;
                }
            }
            if (endRecord < 0) throw Invalid();
            ulong eocd = (ulong)endRecord, end = eocd;
            if (U16(b, eocd + 4) != 0 || U16(b, eocd + 6) != 0) throw Invalid();
            ulong count = U16(b, eocd + 10), onDisk = U16(b, eocd + 8);
            ulong size = U32(b, eocd + 12), start = U32(b, eocd + 16);
            bool zip64 = count == ushort.MaxValue || onDisk == ushort.MaxValue ||
                         size == uint.MaxValue || start == uint.MaxValue;
            if (zip64) {
                if (eocd < 20) throw Invalid();
                ulong locator = eocd - 20;
                if (U32(b, locator) != 0x07064b50 || U32(b, locator + 4) != 0 ||
                    U32(b, locator + 16) != 1) throw Invalid();
                ulong record = U64(b, locator + 8);
                Range(record, 56, locator);
                ulong recordSize = U64(b, record + 4);
                if (U32(b, record) != 0x06064b50 || recordSize < 44 ||
                    recordSize != locator - record - 12 || U32(b, record + 16) != 0 ||
                    U32(b, record + 20) != 0) throw Invalid();
                ulong count64 = U64(b, record + 32), size64 = U64(b, record + 40), start64 = U64(b, record + 48);
                if (U64(b, record + 24) != count64 ||
                    (count != ushort.MaxValue && count != count64) ||
                    (onDisk != ushort.MaxValue && onDisk != count64) ||
                    (size != uint.MaxValue && size != size64) ||
                    (start != uint.MaxValue && start != start64)) throw Invalid();
                count = onDisk = count64; size = size64; start = start64; end = record;
            }
            if (count != onDisk || count != (ulong)expectedCount) throw Invalid();
            Range(start, size, end);
            ulong directoryEnd = start + size, position = start;
            var entries = new BaselineZipEntry[expectedCount];
            for (int i = 0; i < entries.Length; i++) {
                Range(position, 46, directoryEnd);
                if (U32(b, position) != 0x02014b50) throw Invalid();
                ushort nameLength = U16(b, position + 28), extraLength = U16(b, position + 30);
                ulong next = position + 46 + nameLength + extraLength + U16(b, position + 32);
                Range(position, next - position, directoryEnd);
                var entry = new BaselineZipEntry {
                    Flags = U16(b, position + 8), Method = U16(b, position + 10),
                    Crc = U32(b, position + 16), CompressedLength = U32(b, position + 20),
                    Length = U32(b, position + 24), LocalOffset = U32(b, position + 42),
                    DirectoryOffset = start, NameOffset = position + 46, NameLength = nameLength
                };
                ulong disk = U16(b, position + 34);
                try {
                    Extra64(b, position + 46 + nameLength, extraLength, ref entry.Length,
                            ref entry.CompressedLength, ref entry.LocalOffset, ref disk);
                    if (disk != 0) entry.Valid = false;
                } catch (InvalidDataException) { entry.Valid = false; }
                entries[i] = entry;
                position = next;
            }
            // An optional central-directory digital signature is metadata, not content.
            if (position != directoryEnd) {
                Range(position, 6, directoryEnd);
                if (U32(b, position) != 0x05054b50 ||
                    position + 6 + U16(b, position + 4) != directoryEnd) throw Invalid();
            }
            return entries;
        }

        static bool DescriptorMatches(byte[] b, ulong p, ulong end, BaselineZipEntry e, bool wide) {
            ulong width = wide ? 20UL : 12UL;
            if (p > end || width > end - p || U32(b, p) != e.Crc) return false;
            return wide
                ? U64(b, p + 4) == e.CompressedLength && U64(b, p + 12) == e.Length
                : U32(b, p + 4) == e.CompressedLength && U32(b, p + 8) == e.Length;
        }

        static ulong DataOffset(byte[] b, BaselineZipEntry e) {
            if (!e.Valid || (e.Flags & 0x41) != 0 || (e.Method != 0 && e.Method != 8)) throw Invalid();
            ulong p = e.LocalOffset;
            Range(p, 30, e.DirectoryOffset);
            if (U32(b, p) != 0x04034b50 || U16(b, p + 6) != e.Flags ||
                U16(b, p + 8) != e.Method || U16(b, p + 26) != e.NameLength) throw Invalid();
            ushort extraLength = U16(b, p + 28);
            ulong data = p + 30 + e.NameLength + extraLength;
            Range(p, data - p, e.DirectoryOffset);
            for (int i = 0; i < e.NameLength; i++)
                if (b[(int)(p + 30) + i] != b[(int)e.NameOffset + i]) throw Invalid();
            ulong length = U32(b, p + 22), packed = U32(b, p + 18), local = 0, disk = 0;
            Extra64(b, p + 30 + e.NameLength, extraLength, ref length, ref packed, ref local, ref disk);
            uint crc = U32(b, p + 14);
            bool descriptor = (e.Flags & 8) != 0;
            if (descriptor) {
                if ((crc != 0 && crc != e.Crc) || (length != 0 && length != e.Length) ||
                    (packed != 0 && packed != e.CompressedLength)) throw Invalid();
            } else if (crc != e.Crc || length != e.Length || packed != e.CompressedLength) throw Invalid();
            Range(data, e.CompressedLength, e.DirectoryOffset);
            if (descriptor) {
                ulong at = data + e.CompressedLength;
                bool matches = DescriptorMatches(b, at, e.DirectoryOffset, e, false) ||
                               DescriptorMatches(b, at, e.DirectoryOffset, e, true);
                if (!matches && at <= e.DirectoryOffset && e.DirectoryOffset - at >= 4 &&
                    U32(b, at) == 0x08074b50)
                    matches = DescriptorMatches(b, at + 4, e.DirectoryOffset, e, false) ||
                              DescriptorMatches(b, at + 4, e.DirectoryOffset, e, true);
                if (!matches) throw Invalid();
            }
            return data;
        }

        static uint[] CreateCrcTable() {
            var table = new uint[256];
            for (uint i = 0; i < table.Length; i++) {
                uint value = i;
                for (int bit = 0; bit < 8; bit++)
                    value = (value & 1) != 0 ? 0xedb88320U ^ (value >> 1) : value >> 1;
                table[i] = value;
            }
            return table;
        }

        sealed class DeflateBits {
            readonly byte[] bytes;
            readonly int end;
            uint bits;
            int available;
            public int Position;
            public DeflateBits(byte[] bytes, int start, int count) {
                this.bytes = bytes; Position = start; end = start + count;
            }
            public int Read(int count) {
                while (available < count) {
                    if (Position == end) throw Invalid();
                    bits |= (uint)bytes[Position++] << available;
                    available += 8;
                }
                int value = (int)(bits & ((1U << count) - 1));
                bits >>= count; available -= count;
                return value;
            }
            public void Align() { bits = 0; available = 0; }
            public void Skip(int count) {
                if (count > end - Position) throw Invalid();
                Position += count;
            }
        }

        sealed class Huffman {
            readonly int[] counts = new int[16], symbols;
            public Huffman(int[] lengths) {
                symbols = new int[lengths.Length];
                foreach (int length in lengths) counts[length]++;
                int left = 1;
                for (int length = 1; length <= 15; length++) {
                    left = (left << 1) - counts[length];
                    if (left < 0) throw Invalid();
                }
                var offsets = new int[16];
                for (int length = 1; length < 15; length++) offsets[length + 1] = offsets[length] + counts[length];
                for (int symbol = 0; symbol < lengths.Length; symbol++)
                    if (lengths[symbol] != 0) symbols[offsets[lengths[symbol]]++] = symbol;
            }
            public int Decode(DeflateBits bits) {
                int code = 0, first = 0, index = 0;
                for (int length = 1; length <= 15; length++) {
                    code |= bits.Read(1);
                    if (code < first + counts[length]) return symbols[index + code - first];
                    index += counts[length];
                    first = (first + counts[length]) << 1;
                    code <<= 1;
                }
                throw Invalid();
            }
        }

        static readonly int[] CodeOrder = { 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15 };
        static readonly int[] LengthBase = { 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258 };
        static readonly int[] LengthExtra = { 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0 };
        static readonly int[] DistanceBase = { 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577 };
        static readonly int[] DistanceExtra = { 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13 };
        static readonly Huffman FixedLiteral = FixedTree(false), FixedDistance = FixedTree(true);
        static Huffman FixedTree(bool distance) {
            var lengths = new int[distance ? 32 : 288];
            for (int i = 0; i < lengths.Length; i++)
                lengths[i] = distance ? 5 : i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
            return new Huffman(lengths);
        }

        static void DynamicTrees(DeflateBits bits, out Huffman literal, out Huffman distance) {
            int literalCount = bits.Read(5) + 257, distanceCount = bits.Read(5) + 1, codeCount = bits.Read(4) + 4;
            if (literalCount > 286) throw Invalid();
            var codeLengths = new int[19];
            for (int i = 0; i < codeCount; i++) codeLengths[CodeOrder[i]] = bits.Read(3);
            var codeTree = new Huffman(codeLengths);
            var lengths = new int[literalCount + distanceCount];
            for (int i = 0; i < lengths.Length;) {
                int symbol = codeTree.Decode(bits);
                if (symbol < 16) { lengths[i++] = symbol; continue; }
                if (symbol == 16 && i == 0) throw Invalid();
                int repeat = symbol == 16 ? bits.Read(2) + 3 : symbol == 17 ? bits.Read(3) + 3 : bits.Read(7) + 11;
                int value = symbol == 16 ? lengths[i - 1] : 0;
                if (repeat > lengths.Length - i) throw Invalid();
                while (repeat-- > 0) lengths[i++] = value;
            }
            if (lengths[256] == 0) throw Invalid();
            var literalLengths = new int[literalCount];
            var distanceLengths = new int[distanceCount];
            Array.Copy(lengths, literalLengths, literalCount);
            Array.Copy(lengths, literalCount, distanceLengths, 0, distanceCount);
            literal = new Huffman(literalLengths); distance = new Huffman(distanceLengths);
        }

        static void ValidateDeflate(byte[] b, int start, int count, long expected) {
            // DeflateStream also tolerates premature compressed EOF. Validate
            // RFC 1951 framing without producing a second copy of the output.
            // Both the bit reader and decoded-length counter are bounded.
            var bits = new DeflateBits(b, start, count);
            long produced = 0;
            bool final;
            do {
                final = bits.Read(1) != 0;
                int kind = bits.Read(2);
                if (kind == 0) {
                    bits.Align();
                    int length = bits.Read(16);
                    if ((length ^ bits.Read(16)) != 65535) throw Invalid();
                    bits.Skip(length); produced += length;
                } else {
                    Huffman literal, distance;
                    if (kind == 1) { literal = FixedLiteral; distance = FixedDistance; }
                    else if (kind == 2) DynamicTrees(bits, out literal, out distance);
                    else throw Invalid();
                    while (true) {
                        int symbol = literal.Decode(bits);
                        if (symbol == 256) break;
                        if (symbol < 256) produced++;
                        else {
                            if (symbol > 285) throw Invalid();
                            int length = LengthBase[symbol - 257] + bits.Read(LengthExtra[symbol - 257]);
                            int dist = distance.Decode(bits);
                            if (dist >= 30 || DistanceBase[dist] + bits.Read(DistanceExtra[dist]) > produced) throw Invalid();
                            produced += length;
                        }
                        if (produced > expected) throw Invalid();
                    }
                }
                if (produced > expected) throw Invalid();
            } while (!final);
            if (produced != expected || bits.Position != start + count) throw Invalid();
        }

        public static byte[] ReadEntry(byte[] b, BaselineZipEntry entry, System.Collections.IDictionary budget) {
            ulong data = DataOffset(b, entry);
            long read = Convert.ToInt64(budget["read"]);
            using (var raw = new MemoryStream(b, (int)data, (int)entry.CompressedLength, false))
            using (Stream source = entry.Method == 8
                ? (Stream)new DeflateStream(raw, CompressionMode.Decompress, true) : raw)
            using (var content = new MemoryStream()) {
                var buffer = new byte[81920];
                uint crc = uint.MaxValue;
                while (content.Length <= EntryLimit && read <= ArchiveLimit) {
                    int remaining = (int)Math.Min(buffer.Length,
                        Math.Min(EntryLimit + 1 - content.Length, ArchiveLimit + 1 - read));
                    int count = source.Read(buffer, 0, remaining);
                    if (count == 0) {
                        if ((ulong)content.Length != entry.Length || (crc ^ uint.MaxValue) != entry.Crc)
                            throw Invalid();
                        if (entry.Method == 8) ValidateDeflate(b, (int)data, (int)entry.CompressedLength, content.Length);
                        break;
                    }
                    read += count;
                    // PowerShell does not copy ref arguments back on a thrown
                    // invocation. Mutate the shared budget before any validation.
                    budget["read"] = read;
                    for (int i = 0; i < count; i++) crc = CrcTable[(crc ^ buffer[i]) & 255] ^ (crc >> 8);
                    content.Write(buffer, 0, count);
                }
                // Oversize output is returned for the caller's limit classification,
                // not accepted as a pack. Its bytes always remain in the budget.
                return content.ToArray();
            }
        }
    }
}
'@
}

function Read-IdsBaselineArchiveEntry {
    param([byte[]]$Bytes, $Entry, $Budget)
    return ,([Ids.BaselineZipReader]::ReadEntry($Bytes, $Entry, $Budget))
}

function ConvertFrom-IdsBaselineArchiveText {
    param([byte[]]$Bytes)
    # UTF-32 LE shares the UTF-16 LE prefix, but is not a supported encoding.
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) {
        throw [Text.DecoderFallbackException]::new((Get-IdsText -Key 'text.utf_32_text_is_not_supported'))
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
    $unreadable = (Get-IdsText -Key 'text.could_not_be_read_encrypted_corrupt_or_unsupported_compression')
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
            throw [ArgumentException]::new((Get-IdsText -Key 'text.the_file_is_not_a_valid_zip_archive'))
        }
        if ($entries.Count -gt 1000) { throw [ArgumentException]::new((Get-IdsText -Key 'text.archive_entry_limit_exceeded_1_000_entries')) }
        $jsonCount = 0
        foreach ($entry in $entries) {
            $name = $entry.FullName
            if ($name.StartsWith('/') -or $name.StartsWith('\') -or $name.Contains(':') -or
                (($name -split '[/\\]') -contains '..')) {
                throw [ArgumentException]::new((Get-IdsText -Key 'text.archive_entry_names_must_be_relative_without_or_segments'))
            }
            if ($name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { $jsonCount++ }
        }
        if ($jsonCount -gt 500) { throw [ArgumentException]::new((Get-IdsText -Key 'text.archive_json_entry_limit_exceeded_500_entries')) }
        Initialize-IdsBaselineArchiveReader
        try { $metadata = @([Ids.BaselineZipReader]::ReadDirectory($Bytes, $entries.Count)) }
        catch [IO.InvalidDataException] { throw [ArgumentException]::new((Get-IdsText -Key 'text.the_file_is_not_a_valid_zip_archive')) }

        for ($entryIndex = 0; $entryIndex -lt $entries.Count; $entryIndex++) {
            $entry = $entries[$entryIndex]
            $info = $metadata[$entryIndex]
            $name = $entry.FullName
            if ($name.EndsWith('/') -or $name.EndsWith('\')) { continue }
            if ($name.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = (Get-IdsText -Key 'text.nested_zip_archives_are_not_opened_extract_and_upload_the_inner_zip') })
                continue
            }
            if (-not $name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { $ignored++; continue }
            $encrypted = $entry.PSObject.Properties['IsEncrypted']
            if (($encrypted -and $encrypted.Value) -or ($info.Flags -band 0x41) -or -not $info.Valid -or
                $info.Length -ne $entry.Length -or $info.CompressedLength -ne $entry.CompressedLength) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = $unreadable })
                continue
            }
            if ($entry.Length -gt 10MB) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = (Get-IdsText -Key 'text.json_entry_exceeds_the_10_mib_limit') })
                continue
            }
            $content = $null
            try { $content = Read-IdsBaselineArchiveEntry $Bytes $info $budget }
            catch [IO.InvalidDataException], [IO.IOException], [NotSupportedException], [InvalidOperationException] { $content = $null }
            # Outside the entry catch: the budget fails the whole request.
            if ($budget.read -gt 64MB) { throw [IO.InvalidDataException]::new((Get-IdsText -Key 'text.archive_json_read_limit_exceeded_64_mib')) }
            if ($null -eq $content) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = $unreadable })
                continue
            }
            if ($content.Length -gt 10MB) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = (Get-IdsText -Key 'text.json_entry_exceeds_the_10_mib_limit') })
                continue
            }
            if ($content.Length -ne $entry.Length) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = $unreadable })
                continue
            }
            try { $text = ConvertFrom-IdsBaselineArchiveText $content } catch {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = (Get-IdsText -Key 'text.not_valid_utf_8_or_utf_16_text') })
                continue
            }
            try { $document = [Text.Json.JsonDocument]::Parse($text, $options) } catch {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = (Get-IdsText -Key 'text.invalid_json_or_nesting_deeper_than_64_levels') })
                continue
            }
            try { $value = ConvertFrom-IdsPackJsonElement $document.RootElement } catch {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = (Get-IdsText -Key 'text.invalid_json_arg0' -Arguments @{ arg0 = ($_.Exception.Message) }) })
                continue
            } finally { $document.Dispose() }
            if ($value -is [Collections.IDictionary] -and $value.Contains('schemaVersion')) {
                $packBytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
                try { [void](Read-IdsBaselinePack -Bytes $packBytes) } catch {
                    $skipped.Add([pscustomobject]@{ entry = $name; reason = (Get-IdsText -Key 'text.invalid_rule_pack_arg0' -Arguments @{ arg0 = ($_.Exception.Message) }) })
                    continue
                }
                $packs.Add($packBytes)
                continue
            }
            $found = Get-IdsBaselineArchivePolicies $value
            if ($null -eq $found) {
                $skipped.Add([pscustomobject]@{ entry = $name; reason = (Get-IdsText -Key 'text.not_a_settings_catalog_policy_or_rule_pack') })
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
