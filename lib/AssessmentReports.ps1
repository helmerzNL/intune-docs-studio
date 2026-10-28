<#
    Standalone, customer-owned assessment evidence. Both formats use the same
    allowlisted projection, never collection/authentication objects. Array
    ordering is canonical; typed values and unavailable percentages stay typed.

    ConvertTo-IdsAssessmentMarkdown renders a schema-1 Result without I/O.
    Write-IdsAssessmentReports publishes a new assessment.md/assessment.json
    pair and returns root (the new run directory), markdownPath and jsonPath.
    OutputPath, InstallRoot and ExportRoot must be absolute, mutually disjoint
    filesystem trees without reparse-point ancestors. Reports are never pruned,
    overwritten, exported to the documentation tree, committed or pushed.

    Optional Result.sources preserves normalized source completeness; absent
    sources becomes []. Collection limitations remain in collectionIssues.
    Tenant accepts identity/display fields only; template and assignment
    metadata are also explicitly projected. Unknown fields are never serialized.
#>

function Get-IdsReportMember {
    param($Object, [string]$Name)
    if ($Object -is [Collections.IDictionary]) { return ,$Object[$Name] }
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return ,$Object.PSObject.Properties[$Name].Value
    }
}

function Copy-IdsReportRecord {
    param($InputObject, [string]$Kind)
    $schema = switch -CaseSensitive ($Kind) {
        Result { [ordered]@{
            schemaVersion = 'number'; runId = 'text'; generatedAt = 'text'; tenant = 'Tenant'; context = 'Context'
            packs = 'Pack[]'; summaries = 'Summary[]'; controls = 'Control[]'; policies = 'Policy[]'
            collectionIssues = 'Issue[]'; sources = 'Source[]'
        } }
        Tenant { [ordered]@{ id = 'text'; tenantId = 'text'; name = 'text'; displayName = 'text'; defaultDomain = 'text' } }
        Context { [ordered]@{ platforms = 'text[]'; osVersions = 'Platforms'; enrollmentModes = 'Platforms' } }
        Platforms { [ordered]@{ windows11 = 'text'; macos = 'text'; iosIpados = 'text'; androidEnterprise = 'text' } }
        Pack { [ordered]@{
            schemaVersion = 'number'; id = 'text'; version = 'text'; framework = 'text'; frameworkVersion = 'text'
            classification = 'text'; platform = 'text'; profile = 'text'; sourceRevision = 'text'
            sha256 = 'text'; origin = 'text'; coverage = 'Coverage'; sources = 'Reference[]'
        } }
        Coverage { [ordered]@{ inventory = 'text'; totalSourceControls = 'number' } }
        Reference { [ordered]@{ id = 'text'; url = 'text'; revision = 'text'; retrievedOn = 'text'; reference = 'text' } }
        Summary { [ordered]@{
            packId = 'text'; platform = 'text'; profile = 'text'; inventory = 'text'; counts = 'Counts'
            assessed = 'number'; coverageDenominator = 'number'; coveragePercent = 'number'; alignmentPercent = 'number'
        } }
        Counts { [ordered]@{
            aligned = 'number'; misaligned = 'number'; missing = 'number'
            potentialConflict = 'number'; notApplicable = 'number'; notAssessed = 'number'
        } }
        Control { [ordered]@{
            packId = 'text'; packVersion = 'text'; platform = 'text'; profile = 'text'
            controlId = 'text'; title = 'text'; status = 'status'; reason = 'text'
            expected = 'Mapping[]'; observed = 'Observation[]'; policyResults = 'PolicyResult[]'; references = 'Reference[]'
        } }
        Mapping { [ordered]@{
            family = 'text'; policyTypes = 'text[]'; settingId = 'text'; property = 'text'; instancePath = 'text'
            valueType = 'text'; operator = 'text'; caseSensitive = 'boolean'
        } }
        Observation { [ordered]@{
            policyKey = 'text'; family = 'text'; settingId = 'text'; property = 'text'; instancePath = 'text'
            valueType = 'text'; configured = 'boolean'; secret = 'boolean'; supported = 'boolean'
        } }
        PolicyResult { [ordered]@{
            policyKey = 'text'; status = 'status'; reason = 'text'; expected = 'Mapping[]'; observed = 'Observation[]'
            assigned = 'boolean'; assignmentsComplete = 'boolean'
        } }
        Policy { [ordered]@{
            key = 'text'; id = 'text'; name = 'text'; family = 'text'; policyType = 'text'; platform = 'text'
            template = 'Template'; osMin = 'text'; osMax = 'text'; enrollmentMode = 'text'
            windowsFamily = 'boolean'; osApplicabilityRule = 'OsApplicabilityRule'; unsupportedApplicability = 'boolean'
            assignments = 'Assignment[]'; settingsComplete = 'boolean'; assignmentsComplete = 'boolean'
        } }
        Template { [ordered]@{
            id = 'text'; templateId = 'text'; displayName = 'text'; templateDisplayName = 'text'
            templateFamily = 'text'; templateType = 'text'; platformType = 'text'
            templateDisplayVersion = 'text'; version = 'number'; isDeprecated = 'boolean'
        } }
        OsApplicabilityRule { [ordered]@{ minOSVersion = 'text'; maxOSVersion = 'text'; ruleType = 'text'; supported = 'boolean' } }
        Assignment { [ordered]@{ id = 'text'; intent = 'text'; source = 'text'; sourceId = 'text'; target = 'Target' } }
        Target { [ordered]@{
            '@odata.type' = 'text'; groupId = 'text'; groupDisplayName = 'text'; collectionId = 'text'
            deviceAndAppManagementAssignmentFilterId = 'text'; deviceAndAppManagementAssignmentFilterType = 'text'
        } }
        Issue { [ordered]@{ family = 'text'; policyKey = 'text'; stage = 'text'; statusCode = 'number'; reason = 'text' } }
        Source { [ordered]@{ family = 'text'; platform = 'text'; complete = 'boolean'; errors = 'Issue[]' } }
        default { throw "Unsupported assessment report record: $Kind." }
    }
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -isnot [Collections.IDictionary] -and $InputObject -isnot [pscustomobject]) {
        throw "Assessment report $Kind must be a record."
    }
    $record = [ordered]@{}
    foreach ($field in $schema.Keys) {
        $type = $schema[$field]
        $value = Get-IdsReportMember $InputObject $field
        if ($type.EndsWith('[]')) {
            $itemType = $type.Substring(0, $type.Length - 2)
            $record[$field] = @(foreach ($item in $value) {
                if ($null -ne $item) { Copy-IdsReportField $item $itemType }
            }) | Sort-Object { ConvertTo-Json -InputObject $_ -Depth 64 -Compress } -CaseSensitive
            $record[$field] = @($record[$field])
        } else {
            $record[$field] = Copy-IdsReportField $value $type
        }
    }
    if ($Kind -ceq 'Mapping') {
        $record.expected = Copy-IdsReportTypedValue (Get-IdsReportMember $InputObject expected) $record.valueType ($record.operator -ceq 'in')
    } elseif ($Kind -ceq 'Observation') {
        $record.value = if ($record.secret -ne $false -or $record.supported -ne $true) { $null }
            else { Copy-IdsReportTypedValue (Get-IdsReportMember $InputObject value) $record.valueType }
    }
    return [pscustomobject]$record
}

function Copy-IdsReportField {
    param($Value, [string]$Type)
    if ($null -eq $Value) { return $null }
    $valid = switch -CaseSensitive ($Type) {
        text { $Value -is [string] }
        boolean { $Value -is [bool] }
        number {
            $Value -is [ValueType] -and [Type]::GetTypeCode($Value.GetType()) -in @(
                [TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16,
                [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64,
                [TypeCode]::Decimal, [TypeCode]::Single, [TypeCode]::Double
            ) -and -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value)
        }
        status { $Value -is [string] -and $Value -cin @('aligned', 'misaligned', 'missing', 'potentialConflict', 'notApplicable', 'notAssessed') }
        default { return Copy-IdsReportRecord $Value $Type }
    }
    if (-not $valid) { throw "Invalid $Type field in assessment report evidence." }
    return $Value
}

function Copy-IdsReportTypedValue {
    param($Value, [string]$ValueType, [bool]$Membership = $false)
    if ($ValueType -cnotin @('boolean', 'number', 'string', 'stringSet', 'numberSet')) {
        if ($null -eq $Value) { return $null }
        throw 'Unsupported typed assessment report value.'
    }
    if ($null -eq $Value) { return $null }
    $type = if ($ValueType -ceq 'string' -or $ValueType -ceq 'stringSet') { 'text' }
        elseif ($ValueType -ceq 'numberSet') { 'number' } else { $ValueType }
    if ($Membership -or $ValueType.EndsWith('Set')) {
        if ($Value -isnot [Collections.IList]) { throw 'Assessment report set value must be an array.' }
        $items = @(foreach ($item in $Value) {
            if ($null -eq $item) { throw 'Assessment report set cannot contain null.' }
            Copy-IdsReportField $item $type
        })
        return ,@($items | Sort-Object { ConvertTo-Json -InputObject $_ -Compress } -CaseSensitive)
    }
    return Copy-IdsReportField $Value $type
}

function ConvertTo-IdsReportProjection {
    param([pscustomobject]$Result)
    if ($Result.schemaVersion -cne 1) { throw 'Unsupported assessment report schemaVersion; expected 1.' }
    return Copy-IdsReportRecord $Result Result
}

function ConvertTo-IdsReportText {
    param([AllowNull()]$Value)
    # Entities neutralize both HTML and Markdown, including links, table/newline
    # injection and code fences. No imported content is emitted as markup.
    $text = if ($null -eq $Value) { 'not available' } else { [string]$Value }
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $text.ToCharArray()) {
        if ($character -in @('&', '<', '>', '|', '[', ']', '(', ')', '*', '_', '`', '\', '#', '!', '+', '-', '{', '}', '~', "`r", "`n")) {
            [void]$builder.Append("&#$([int]$character);")
        } else { [void]$builder.Append($character) }
    }
    return $builder.ToString()
}

function Format-IdsReportRecord {
    param($Record)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('| Field | Evidence |')
    $lines.Add('| --- | --- |')
    foreach ($property in $Record.PSObject.Properties) {
        $value = $property.Value
        if ($null -ne $value -and $value -isnot [string]) {
            $value = ConvertTo-Json -InputObject $value -Depth 64 -Compress
        }
        $lines.Add("| $(ConvertTo-IdsReportText $property.Name) | $(ConvertTo-IdsReportText $value) |")
    }
    return ($lines -join "`n")
}

function ConvertTo-IdsProjectedAssessmentMarkdown {
    param($Result)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Policy configuration alignment assessment')
    $lines.Add('')
    $lines.Add('This is configuration alignment, not effective device compliance or certification. Assignments are evidence only; group membership, filters and effective targeting are not resolved. Potential conflict does not establish targeting overlap or an Intune conflict.')
    $lines.Add('Pack origin distinguishes application-reviewed bundled resources from customer-imported packs. Imported framework/classification labels are author-declared, not verified Microsoft authority. Windows-family policy metadata is not discovered Windows 11 inventory; a supplied target build establishes comparison context only.')
    $lines.Add('')
    $lines.Add('Missing means absent/not configured only in the mapped families and policy types read completely for this rule, not tenant-wide absence. Partial packs cover only their listed checks, not the entire benchmark. User-selected context is not discovered device inventory. Legacy-only mappings do not cover equivalent modern policy families. Personal-only iOS/iPadOS and Android profiles do not establish organization-owned coverage. A macOS beta/deprecated template reference does not establish current-template or device encryption compliance.')
    $lines.Add('')
    $lines.Add('Assessment coverage = assessed / listed controls excluding notApplicable; unknown applicability stays in the denominator. Configuration alignment = aligned / assessed (aligned, misaligned, missing, potentialConflict). Null percentages are not available, never 100%.')
    $lines.Add('')
    $lines.Add('Status labels: aligned (Aligned), misaligned (Misaligned), missing (Missing), potentialConflict (Potential conflict), notApplicable (Not applicable), notAssessed (Not assessed).')
    $lines.Add('')
    $lines.Add('## Run identity and user-selected context')
    $lines.Add((Format-IdsReportRecord ([pscustomobject]@{
        schemaVersion = $Result.schemaVersion; runId = $Result.runId; generatedAt = $Result.generatedAt
        tenant = $Result.tenant; context = $Result.context
    })))
    foreach ($section in @(
        @{ title = 'Pack identity, sources and coverage boundaries'; field = 'packs'; heading = 'id' }
        @{ title = 'Assessment coverage and Configuration alignment summaries'; field = 'summaries'; heading = 'packId' }
        @{ title = 'Control evidence'; field = 'controls'; heading = 'controlId' }
        @{ title = 'Source policies and assignment evidence'; field = 'policies'; heading = 'key' }
        @{ title = 'Collection source completeness'; field = 'sources'; heading = 'family' }
        @{ title = 'Collection limitations'; field = 'collectionIssues'; heading = 'stage' }
    )) {
        $lines.Add('')
        $lines.Add("## $($section.title)")
        foreach ($record in $Result.($section.field)) {
            $lines.Add('')
            $lines.Add("### $(ConvertTo-IdsReportText $record.($section.heading))")
            $lines.Add((Format-IdsReportRecord $record))
        }
        if (@($Result.($section.field)).Count -eq 0) { $lines.Add('No entries supplied.') }
    }
    return (($lines -join "`n") + "`n")
}

function ConvertTo-IdsAssessmentMarkdown {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    return ConvertTo-IdsProjectedAssessmentMarkdown (ConvertTo-IdsReportProjection $Result)
}

function Assert-IdsReportDirectoryPath {
    param([string]$Path)
    $current = $Path
    while ($current) {
        try {
            $attributes = [IO.File]::GetAttributes($current)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Assessment report roots must not contain a reparse point.'
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
                throw 'Assessment report roots must be directories.'
            }
        } catch [IO.FileNotFoundException] {
            # A nonexistent suffix is allowed, but every existing ancestor is checked.
        } catch [IO.DirectoryNotFoundException] {
        }
        $parent = [IO.Directory]::GetParent($current)
        $current = if ($null -ne $parent) { $parent.FullName } else { $null }
    }
}

function Get-IdsReportCanonicalRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path) -or
        $Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) {
        throw 'Assessment report roots must be ordinary fully qualified absolute filesystem paths.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    foreach ($component in ($Path.Substring([IO.Path]::GetPathRoot($Path).Length) -split '[\\/]')) {
        if ($component -in @('', '.', '..')) { continue }
        if ($component -match '[<>:"|?*\x00-\x1f]' -or $component -match '[. ]$' -or
            $component -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
            throw 'Assessment report root contains an ambiguous filesystem component.'
        }
    }
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    Assert-IdsReportDirectoryPath $full
    return $full
}

function Assert-IdsReportDistinctRoots {
    param([string[]]$Roots)
    for ($i = 0; $i -lt $Roots.Count; $i++) {
        for ($j = $i + 1; $j -lt $Roots.Count; $j++) {
            $a = $Roots[$i].TrimEnd('\') + '\'
            $b = $Roots[$j].TrimEnd('\') + '\'
            if ($a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or
                $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Assessment installation, export and report roots must not overlap.'
            }
        }
    }
}

function Write-IdsAssessmentReports {
    param(
        [Parameter(Mandatory)][pscustomobject]$Result,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ExportRoot
    )
    $output = Get-IdsReportCanonicalRoot $OutputPath
    $install = Get-IdsReportCanonicalRoot $InstallRoot
    $export = Get-IdsReportCanonicalRoot $ExportRoot
    Assert-IdsReportDistinctRoots @($output, $install, $export)
    $projection = ConvertTo-IdsReportProjection $Result
    $stage = $null
    try {
        [void][IO.Directory]::CreateDirectory($output)
        foreach ($path in @($output, $install, $export)) { Assert-IdsReportDirectoryPath $path }
        $unique = [guid]::NewGuid().ToString('N')
        $candidate = Join-Path $output ".assessment-stage-$unique"
        $final = Join-Path $output "assessment-$unique"
        if ([IO.Directory]::Exists($candidate) -or [IO.File]::Exists($candidate) -or
            [IO.Directory]::Exists($final) -or [IO.File]::Exists($final)) { throw 'Assessment run directory already exists.' }
        [void][IO.Directory]::CreateDirectory($candidate)
        $stage = $candidate
        Assert-IdsReportDirectoryPath $stage
        $json = ConvertTo-Json -InputObject $projection -Depth 64
        Set-Content -LiteralPath (Join-Path $stage 'assessment.json') -Value $json -Encoding utf8 -NoNewline -ErrorAction Stop
        $markdown = ConvertTo-IdsProjectedAssessmentMarkdown $projection
        Set-Content -LiteralPath (Join-Path $stage 'assessment.md') -Value $markdown -Encoding utf8 -NoNewline -ErrorAction Stop
        foreach ($path in @($stage, $install, $export)) { Assert-IdsReportDirectoryPath $path }
        [IO.Directory]::Move($stage, $final)
        $stage = $null
        return [pscustomobject]@{
            root = $final
            markdownPath = Join-Path $final 'assessment.md'
            jsonPath = Join-Path $final 'assessment.json'
        }
    } catch {
        throw [IO.IOException]::new('Assessment report publication failed; no successful report pair was returned.', $_.Exception)
    } finally {
        if ($null -ne $stage) {
            try {
                Assert-IdsReportDirectoryPath $stage
                # Never recurse or prune: only our two staged files and our empty
                # invocation-owned directory may be removed.
                foreach ($name in @('assessment.json', 'assessment.md')) {
                    [IO.File]::Delete((Join-Path $stage $name))
                }
                [IO.Directory]::Delete($stage, $false)
            } catch {
                Write-Warning 'Unable to clean the assessment staging directory; no report pair was published.'
            }
        }
    }
}
