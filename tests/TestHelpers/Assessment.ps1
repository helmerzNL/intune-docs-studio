function New-IdsTestPackBytes {
    param([string]$Platform = 'windows11')
    $pack = @{
        schemaVersion = 1; id = 'synthetic-pack'; version = '1.0.0'
        framework = 'Synthetic'; frameworkVersion = '1'
        classification = 'recommendations'; platform = $Platform
        profile = 'test'; sourceRevision = 'synthetic-v1'
        sources = @(@{ id = 'source'; url = 'https://example.invalid/rules'
            revision = 'synthetic-v1'; retrievedOn = '2026-10-28' })
        coverage = @{ inventory = 'partial'; totalSourceControls = $null }
        controls = @(@{
            id = 'SYN-1'; title = 'Synthetic required setting'
            sourceIds = @('source'); reference = 'SYN-1'; manualReason = $null
            applicability = @{ osMin = $null; osMax = $null; enrollmentModes = @() }
            mappings = @(@{
                family = 'settingsCatalog'; policyTypes = @('configurationPolicy')
                settingId = 'synthetic.required'; property = $null
                instancePath = $null; valueType = 'boolean'
                operator = 'eq'; expected = $true; caseSensitive = $true
            })
        })
    }

    return ,([Text.Encoding]::UTF8.GetBytes(($pack | ConvertTo-Json -Depth 20)))
}

function New-IdsTestAssessmentPolicy {
    param([string]$Family = 'settingsCatalog',
        [string]$PolicyType = 'deviceManagementConfigurationPolicy',
        [object[]]$Settings = @(), $Template = $null)
    [pscustomobject]@{
        key = "${Family}:synthetic"; id = 'synthetic'; name = 'Synthetic Windows 11 fully managed'
        family = $Family; policyType = $PolicyType; platform = $null; template = $Template
        osMin = $null; osMax = $null; enrollmentMode = $null
        assignments = @(); settingsComplete = $true; assignmentsComplete = $true
        rawSettings = $Settings
    }
}

function New-IdsTestSettingInstance {
    param([string]$Kind = 'simple', [string]$Id = 'synthetic.setting', $Value = 0)
    $typeKind = $Kind.Substring(0, 1).ToUpperInvariant() + $Kind.Substring(1)
    $instance = @{ '@odata.type' = "#microsoft.graph.deviceManagementConfiguration${typeKind}SettingInstance"; settingDefinitionId = $Id }
    $instance["${Kind}SettingValue"] = $Value
    return $instance
}

function New-IdsTestAssessmentCollection {
    param([object[]]$Policies = @())
    [pscustomobject]@{ policies = $Policies; sources = @(); issues = @() }
}

function Assert-IdsTestMarkdownObservations {
    param([string]$Section, $Control)
    $row = [regex]::Match($Section, '(?m)^\| observed \| (.*) \|$')
    $row.Success | Should -BeTrue
    $records = ConvertFrom-Json -InputObject ([Net.WebUtility]::HtmlDecode($row.Groups[1].Value)) -NoEnumerate
    ConvertTo-Json -InputObject $records -Depth 20 -Compress |
        Should -Be (ConvertTo-Json -InputObject $Control.observed -Depth 20 -Compress)
}

function ConvertTo-IdsTestJsonValue {
    param($Value)
    $document = [Text.Json.JsonDocument]::Parse((ConvertTo-Json -InputObject $Value -Depth 64))
    try { $converted = ConvertFrom-IdsPackJsonElement $document.RootElement } finally { $document.Dispose() }
    return ,$converted
}

function New-IdsTestSettingCollectionInstance {
    param([string]$Kind = 'simple', [string]$Id = 'synthetic.collection', [object[]]$Values = @())
    $typeKind = $Kind.Substring(0, 1).ToUpperInvariant() + $Kind.Substring(1)
    $instance = @{ '@odata.type' = "#microsoft.graph.deviceManagementConfiguration${typeKind}SettingCollectionInstance"; settingDefinitionId = $Id }
    $instance["${Kind}SettingCollectionValue"] = $Values
    return $instance
}

function New-IdsTestBuildKitPolicy {
    param([string]$Name = 'Synthetic L1 policy', [string]$Platforms = 'windows10',
        [object[]]$Instances = @(), [object[]]$Definitions = @())
    $settings = @(for ($index = 0; $index -lt $Instances.Count; $index++) {
        $setting = @{ settingInstance = $Instances[$index] }
        if ($index -eq 0 -and $Definitions.Count -gt 0) { $setting.settingDefinitions = $Definitions }
        $setting
    })
    return ,(ConvertTo-IdsTestJsonValue @{ name = $Name; platforms = $Platforms; technologies = 'mdm'; settings = $settings })
}

function New-IdsTestBuildKitItem {
    param($Policy, [string]$Entry = 'kit/policy.json',
        [DateTimeOffset]$LastWriteTime = [DateTimeOffset]::new(2026, 10, 1, 12, 0, 0, [TimeSpan]::Zero))
    return [pscustomobject]@{ entry = $Entry; policy = $Policy; lastWriteTime = $LastWriteTime }
}

function New-IdsTestZipBytes {
    param([Parameter(Mandatory)][Collections.IDictionary]$Entries, [string]$CompressionLevel = 'Optimal',
        [DateTimeOffset]$LastWriteTime = [DateTimeOffset]::new(2026, 10, 1, 12, 0, 0, [TimeSpan]::Zero))
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.MemoryStream]::new()
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($pair in $Entries.GetEnumerator()) {
                $entry = $archive.CreateEntry([string]$pair.Key, [IO.Compression.CompressionLevel]$CompressionLevel)
                $entry.LastWriteTime = $LastWriteTime
                if ($null -eq $pair.Value) { continue }
                $bytes = $pair.Value
                if ($bytes -isnot [byte[]]) { $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$pair.Value) }
                $content = $entry.Open()
                try { $content.Write($bytes, 0, $bytes.Length) } finally { $content.Dispose() }
            }
        } finally { $archive.Dispose() }
        return ,($stream.ToArray())
    } finally { $stream.Dispose() }
}

function Edit-IdsTestZipFirstEntry {
    param([Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][ValidateSet('Encrypted', 'UnsupportedCompression', 'CorruptData', 'DeclaredLength')][string]$Change,
        [uint32]$Length = 0)
    # These synthetic ZIPs have no comment; the central directory offset is
    # six bytes before the end and the first local header starts at zero.
    $copy = [byte[]]$Bytes.Clone()
    $central = [BitConverter]::ToInt32($copy, $copy.Length - 6)
    switch ($Change) {
        Encrypted { $copy[6] = $copy[6] -bor 1; $copy[$central + 8] = $copy[$central + 8] -bor 1 }
        UnsupportedCompression { $copy[8] = 14; $copy[$central + 10] = 14 }
        CorruptData {
            $start = 30 + [BitConverter]::ToUInt16($copy, 26) + [BitConverter]::ToUInt16($copy, 28)
            $end = $start + [BitConverter]::ToInt32($copy, $central + 20)
            for ($index = $start; $index -lt $end; $index++) { $copy[$index] = 0xFF }
        }
        DeclaredLength {
            [BitConverter]::GetBytes($Length).CopyTo($copy, 22)
            [BitConverter]::GetBytes($Length).CopyTo($copy, $central + 24)
        }
    }
    return ,$copy
}

function New-IdsTestZipVariant {
    param([Parameter(Mandatory)][byte[]]$Content,
        [ValidateSet('None', 'Signed', 'Unsigned')][string]$Descriptor = 'None',
        [switch]$Zip64, [switch]$LocalZip64, [string]$CompressionLevel = 'Optimal',
        [string]$Name = 'kit/policy.json', [string]$Comment = '', [byte[]]$Prefix = @(),
        [byte[]]$DeflateData = $null)
    # Reuse .NET's independent compressor/CRC, but write synthetic ZIP
    # metadata explicitly to exercise variants not produced by its seekable writer.
    $original = New-IdsTestZipBytes ([ordered]@{ $Name = $Content }) -CompressionLevel $CompressionLevel
    $crc = [BitConverter]::ToUInt32($original, 14)
    $compressedLength = [BitConverter]::ToUInt32($original, 18)
    $method = [BitConverter]::ToUInt16($original, 8)
    if ($null -ne $DeflateData) { $compressedLength = [uint32]$DeflateData.Length; $method = [uint16]8 }
    $dataOffset = 30 + [BitConverter]::ToUInt16($original, 26) + [BitConverter]::ToUInt16($original, 28)
    $nameBytes = [Text.Encoding]::UTF8.GetBytes($Name)
    $commentBytes = [Text.Encoding]::UTF8.GetBytes($Comment)
    $local64 = $Zip64 -or $LocalZip64
    [uint16]$flags = 0x800
    if ($Descriptor -ne 'None') { $flags = $flags -bor 8 }
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write($Prefix)
        $localOffset = $stream.Position
        $writer.Write([uint32]0x04034b50); $writer.Write([uint16]45)
        $writer.Write($flags); $writer.Write($method)
        $writer.Write([uint16]0x6000); $writer.Write([uint16]0x5d41)
        $writer.Write([uint32]$(if ($Descriptor -eq 'None') { $crc } else { 0 }))
        $writer.Write([uint32]$(if ($local64) { [uint32]::MaxValue } elseif ($Descriptor -eq 'None') { $compressedLength } else { 0 }))
        $writer.Write([uint32]$(if ($local64) { [uint32]::MaxValue } elseif ($Descriptor -eq 'None') { $Content.Length } else { 0 }))
        $writer.Write([uint16]$nameBytes.Length)
        $writer.Write([uint16]$(if ($local64) { 20 } else { 0 }))
        $writer.Write($nameBytes)
        if ($local64) {
            $writer.Write([uint16]1); $writer.Write([uint16]16)
            $writer.Write([uint64]$(if ($Descriptor -eq 'None') { $Content.Length } else { 0 }))
            $writer.Write([uint64]$(if ($Descriptor -eq 'None') { $compressedLength } else { 0 }))
        }
        if ($null -ne $DeflateData) { $writer.Write($DeflateData) }
        else { $writer.Write($original, $dataOffset, $compressedLength) }
        if ($Descriptor -ne 'None') {
            if ($Descriptor -eq 'Signed') { $writer.Write([uint32]0x08074b50) }
            $writer.Write($crc)
            if ($local64) { $writer.Write([uint64]$compressedLength); $writer.Write([uint64]$Content.Length) }
            else { $writer.Write([uint32]$compressedLength); $writer.Write([uint32]$Content.Length) }
        }
        $centralOffset = $stream.Position
        $writer.Write([uint32]0x02014b50); $writer.Write([uint16]45); $writer.Write([uint16]45)
        $writer.Write($flags); $writer.Write($method)
        $writer.Write([uint16]0x6000); $writer.Write([uint16]0x5d41); $writer.Write($crc)
        $writer.Write([uint32]$(if ($Zip64) { [uint32]::MaxValue } else { $compressedLength }))
        $writer.Write([uint32]$(if ($Zip64) { [uint32]::MaxValue } else { $Content.Length }))
        $writer.Write([uint16]$nameBytes.Length)
        $writer.Write([uint16]$(if ($Zip64) { 28 } else { 0 }))
        $writer.Write([uint16]$commentBytes.Length)
        $writer.Write([uint16]0); $writer.Write([uint16]0); $writer.Write([uint32]0)
        $writer.Write([uint32]$(if ($Zip64) { [uint32]::MaxValue } else { $localOffset }))
        $writer.Write($nameBytes)
        if ($Zip64) {
            $writer.Write([uint16]1); $writer.Write([uint16]24)
            $writer.Write([uint64]$Content.Length); $writer.Write([uint64]$compressedLength)
            $writer.Write([uint64]$localOffset)
        }
        $writer.Write($commentBytes)
        $centralSize = $stream.Position - $centralOffset
        if ($Zip64) {
            $recordOffset = $stream.Position
            $writer.Write([uint32]0x06064b50); $writer.Write([uint64]44)
            $writer.Write([uint16]45); $writer.Write([uint16]45)
            $writer.Write([uint32]0); $writer.Write([uint32]0)
            $writer.Write([uint64]1); $writer.Write([uint64]1)
            $writer.Write([uint64]$centralSize); $writer.Write([uint64]$centralOffset)
            $writer.Write([uint32]0x07064b50); $writer.Write([uint32]0)
            $writer.Write([uint64]$recordOffset); $writer.Write([uint32]1)
        }
        $writer.Write([uint32]0x06054b50); $writer.Write([uint16]0); $writer.Write([uint16]0)
        $count = [uint16]$(if ($Zip64) { [uint16]::MaxValue } else { 1 })
        $writer.Write($count); $writer.Write($count)
        $writer.Write([uint32]$(if ($Zip64) { [uint32]::MaxValue } else { $centralSize }))
        $writer.Write([uint32]$(if ($Zip64) { [uint32]::MaxValue } else { $centralOffset }))
        $writer.Write([uint16]$commentBytes.Length); $writer.Write($commentBytes)
        $writer.Flush()
        return ,($stream.ToArray())
    } finally { $writer.Dispose(); $stream.Dispose() }
}
