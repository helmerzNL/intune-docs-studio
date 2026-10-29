. (Join-Path $PSScriptRoot 'Localization.ps1')

<#
    Standalone, customer-owned assessment evidence. Both formats use the same
    allowlisted projection, never collection/authentication objects. Array
    ordering is canonical; typed values and unavailable percentages stay typed.

    ConvertTo-IdsAssessmentMarkdown renders a schema-1 Result without I/O.
    Write-IdsAssessmentReports publishes a new assessment.md/assessment.json
    pair and returns root (the new run directory), markdownPath and jsonPath.
    OutputPath, InstallRoot and ExportRoot must be absolute, mutually disjoint
    filesystem trees without link/junction ancestors. Non-redirecting Windows
    cloud placeholders are allowed. Reports are never pruned,
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

function Get-IdsAssessmentReasonTemplates {
    # Exact canonical evaluator sentences only; imported/manual wording is not rewritten.
    return [ordered]@{
        'Unsupported or redacted setting evidence.' = 'report.reason.unsupported_evidence'
        'Setting is not configured.' = 'report.reason.unconfigured'
        'Unsupported mapping type, operator, or case sensitivity.' = 'report.reason.unsupported_mapping'
        'Observed value does not have the declared mapping type; coercion is not supported.' = 'report.reason.observed_type'
        'Operator is incompatible with the mapping type.' = 'report.reason.operator_type'
        'Expected value does not have the required typed scalar or set shape.' = 'report.reason.expected_shape'
        'Configured value satisfies the rule.' = 'report.reason.value_satisfies'
        'Configured value violates the rule.' = 'report.reason.value_violates'
        'Selected OS build excludes Windows 11.' = 'report.reason.windows_excluded'
        'Selected OS build is not a known Windows 11 version shape.' = 'report.reason.windows_unknown'
        'Selected platform context is unknown.' = 'report.reason.platform_unknown'
        'Selected platforms exclude this control.' = 'report.reason.platform_excluded'
        'Policy platform applicability is unknown.' = 'report.reason.policy_platform_unknown'
        'Policy platform excludes this context.' = 'report.reason.policy_platform_excluded'
        'Windows-family policy requires an explicit Windows 11 comparison target OS build.' = 'report.reason.windows_target_required'
        'Policy edition or device-mode applicability is unsupported by the comparison context.' = 'report.reason.edition_unsupported'
        'Policy OS applicability rule is malformed or unsupported.' = 'report.reason.os_rule_unsupported'
        'Policy OS applicability requires a known target build.' = 'report.reason.os_target_unknown'
        'Policy OS applicability rule excludes this comparison target.' = 'report.reason.os_target_excluded'
        'Selected enrollment mode applicability is unknown.' = 'report.reason.selected_mode_unknown'
        'Enrollment mode applicability is unknown.' = 'report.reason.mode_unknown'
        'Selected enrollment mode is excluded.' = 'report.reason.mode_excluded'
        'Policy enrollment mode applicability is unknown.' = 'report.reason.policy_mode_unknown'
        'Policy enrollment mode excludes this context.' = 'report.reason.policy_mode_excluded'
        'Applicability established by assessment context and explicit policy metadata.' = 'report.reason.applicability_established'
        'No supported automated mapping is available.' = 'report.reason.no_mapping'
        'Contradictory duplicate evidence for one policy/setting/path identity.' = 'report.reason.duplicate_evidence'
        'Incomplete settings read, unsupported, redacted, or untyped setting evidence.' = 'report.reason.incomplete_settings'
        'Mapped setting is absent or not configured in this policy.' = 'report.reason.policy_missing'
        'Configured values satisfy the rule; this is not device compliance.' = 'report.reason.policy_aligned'
        'Policy is unassigned; matching configuration does not establish device reach.' = 'report.reason.unassigned'
        'Assignment evidence is incomplete; device reach is unknown.' = 'report.reason.assignments_incomplete'
        'Differing configured values across policies; potential conflict only, not proof of overlapping targeting or an Intune conflict.' = 'report.reason.potential_conflict_detail'
        'Configured values violate the rule.' = 'report.reason.values_violate'
        'Mapped setting is absent or not configured across relevant sources.' = 'report.reason.control_missing'
        'Configured values satisfy the rule; this is configuration alignment, not device compliance.' = 'report.reason.control_aligned'
        'Observed potential conflict: differing cross-policy values; targeting overlap is not established.' = 'report.reason.observed_conflict'
        'Observed configured values violate the rule.' = 'report.reason.observed_violation'
    }
}

function Get-IdsAssessmentDisplayReason {
    [CmdletBinding()]
    param([string]$Status, [string]$Reason, [string]$Locale = (Get-IdsLocale))
    $Locale = Resolve-IdsLocale $Locale
    $remaining = $Reason.Trim()
    $parts = [Collections.Generic.List[string]]::new()
    $templates = Get-IdsAssessmentReasonTemplates
    while ($remaining.Length) {
        $consumed = 0
        foreach ($canonical in $templates.Keys) {
            if ($remaining.StartsWith($canonical, [StringComparison]::Ordinal) -and
                ($remaining.Length -eq $canonical.Length -or $remaining[$canonical.Length] -eq ' ')) {
                $parts.Add((Get-IdsText -Key $templates[$canonical] -Locale $Locale))
                $consumed = $canonical.Length
                break
            }
        }
        if (-not $consumed) {
            $key = $null; $arguments = @{}
            if ($remaining -cmatch "\AOS version applicability \((osMin|osMax)\) is unknown\.(?= |\z)") {
                $key = 'report.reason.os_bound_unknown'; $arguments.bound = $Matches[1]
            } elseif ($remaining -cmatch "\AOS version is outside (osMin|osMax)\.(?= |\z)") {
                $key = 'report.reason.os_bound_excluded'; $arguments.bound = $Matches[1]
            } elseif ($remaining -cmatch "\ARelevant source '(settingsCatalog|deviceConfiguration|compliance|admx|intent)' is incomplete or unreported\.(?= |\z)") {
                $key = 'report.reason.source_incomplete'; $arguments.family = $Matches[1]
            } elseif ($remaining -cmatch "\APolicy '([^'`r`n]{1,256})': (?=.)") {
                $key = 'report.reason.policy_prefix'; $arguments.policy = $Matches[1]
            }
            if ($key) {
                $consumed = $Matches[0].Length
                $parts.Add((Get-IdsText -Key $key -Arguments $arguments -Locale $Locale))
            }
        }
        if (-not $consumed) {
            Write-Warning 'IDS localization: unrecognized assessment reason semantics; preserving the canonical technical reason.'
            return $Reason
        }
        $remaining = $remaining.Substring($consumed).TrimStart(' ')
    }
    if ($Locale -eq 'en-GB') { return $Reason }
    return $parts -join ' '
}

function Add-IdsAssessmentPolicyPresentation {
    param($Collection, $Snapshot)
    foreach ($policy in $Snapshot.policies) {
        $inputPolicy = @($Collection.policies | Where-Object key -CEQ $policy.key)[0]
        $tables = @()
        $note = (Get-IdsText -Key 'text.readable_settings_are_limited_to_supported_assessment_evidence_exact_mappings_and_typed_values_remai')
        if ($policy.settingsComplete -eq $true) {
            $settings = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject @($inputPolicy.rawSettings) -Depth 64) -Depth 64 -NoEnumerate
            $tables = @(switch -CaseSensitive ($policy.family) {
                settingsCatalog { Format-IdsSettingsCatalog $settings -AsData }
                admx { Format-IdsAdmxSettings $settings -AsData }
                intent { Format-IdsIntentSettings $settings -AsData }
                { $_ -cin @('deviceConfiguration', 'compliance') } {
                    # Only allowlisted, supported properties enter reports, not the
                    # original documentation payload or its arbitrary properties.
                    $properties = [ordered]@{}
                    foreach ($observation in $Snapshot.observations | Where-Object {
                        $_.policyKey -ceq $policy.key -and $_.supported -eq $true -and $_.secret -eq $false
                    }) { $properties[$observation.property] = $observation.value }
                    Format-IdsTemplateSettings ([pscustomobject]$properties) -AsData
                }
            })
        } else {
            $note = (Get-IdsText -Key 'text.readable_settings_withheld_because_evidence_is_incomplete_secret_or_unsupported_review_collection_li')
        }
        $policy | Add-Member NoteProperty settingsTables @($tables) -Force
        $policy | Add-Member NoteProperty settingsNote $note -Force
    }
}

function Set-IdsAssessmentEvidencePresentation {
    param($Record, $Definitions, [switch]$Expected)
    $name = if ($Record.family -cin @('deviceConfiguration', 'compliance')) {
        Get-IdsPrettyId $Record.property
    } else { Get-IdsSettingName -DefMap $Definitions -Id $Record.settingId }
    $value = if ($Expected) { $Record.expected } else { $Record.value }
    $display = if (-not $Expected -and ($Record.secret -ne $false -or $Record.supported -ne $true)) {
        (Get-IdsText -Key 'text.unavailable_secret_or_unsupported_evidence')
    } elseif (-not $Expected -and $Record.configured -ne $true) {
        (Get-IdsText -Key 'text.not_configured')
    } else {
        $formatted = @(foreach ($item in @($value)) {
            if ($item -is [string] -and $Record.settingId) {
                Get-IdsOptionText -DefMap $Definitions -DefId $Record.settingId -Value $item
            } else { Format-IdsCell $item -PlainText }
        })
        if ($formatted.Count) { $formatted -join ', ' } else { Format-IdsCell $null -PlainText }
    }
    $Record | Add-Member NoteProperty displayName ([string]$name) -Force
    $Record | Add-Member NoteProperty displayValue ([string]$display) -Force
}

function Add-IdsAssessmentEvidencePresentation {
    param($Collection, $Evaluation)
    $byPolicy = @{}
    $allDefinitions = @{}
    foreach ($policy in $Collection.policies) {
        $settings = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject @($policy.rawSettings) -Depth 64) -Depth 64 -NoEnumerate
        $definitions = New-IdsDefinitionMap $settings
        if ($policy.family -ceq 'admx') {
            foreach ($setting in $settings) {
                if ($setting.definition.id) { $definitions[$setting.definition.id] = $setting.definition }
            }
        }
        $byPolicy[$policy.key] = $definitions
        foreach ($id in $definitions.Keys) {
            if (-not $allDefinitions.ContainsKey($id)) { $allDefinitions[$id] = $definitions[$id] }
        }
    }
    foreach ($control in $Evaluation.controls) {
        $control | Add-Member NoteProperty displayReason (Get-IdsAssessmentDisplayReason $control.status $control.reason) -Force
        foreach ($mapping in $control.expected) { Set-IdsAssessmentEvidencePresentation $mapping $allDefinitions -Expected }
        foreach ($observation in $control.observed) {
            Set-IdsAssessmentEvidencePresentation $observation $byPolicy[$observation.policyKey]
        }
        foreach ($result in $control.policyResults) {
            $result | Add-Member NoteProperty displayReason (Get-IdsAssessmentDisplayReason $result.status $result.reason) -Force
            foreach ($mapping in $result.expected) { Set-IdsAssessmentEvidencePresentation $mapping $byPolicy[$result.policyKey] -Expected }
            foreach ($observation in $result.observed) {
                Set-IdsAssessmentEvidencePresentation $observation $byPolicy[$result.policyKey]
            }
        }
    }
}

function Copy-IdsReportRecord {
    param($InputObject, [string]$Kind)
    $schema = switch -CaseSensitive ($Kind) {
        Result { [ordered]@{
            schemaVersion = 'number'; runId = 'text'; generatedAt = 'text'; policySnapshotAt = 'text'; policySource = 'PolicySource'; tenant = 'Tenant'; context = 'Context'
            packs = 'Pack[]'; summaries = 'Summary[]'; controls = 'Control[]'; policies = 'Policy[]'
            collectionIssues = 'Issue[]'; sources = 'Source[]'
        } }
        Tenant { [ordered]@{ id = 'text'; tenantId = 'text'; name = 'text'; displayName = 'text'; defaultDomain = 'text' } }
        PolicySource { [ordered]@{ kind = 'text'; name = 'text'; importedAt = 'text'; format = 'text' } }
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
            controlId = 'text'; title = 'text'; status = 'status'; reason = 'text'; displayReason = 'text'
            expected = 'Mapping[]'; observed = 'Observation[]'; policyResults = 'PolicyResult[]'; references = 'Reference[]'
        } }
        Mapping { [ordered]@{
            family = 'text'; policyTypes = 'text[]'; settingId = 'text'; property = 'text'; instancePath = 'text'
            valueType = 'text'; operator = 'text'; caseSensitive = 'boolean'
            displayName = 'text'; displayValue = 'text'
        } }
        Observation { [ordered]@{
            policyKey = 'text'; family = 'text'; settingId = 'text'; property = 'text'; instancePath = 'text'
            valueType = 'text'; configured = 'boolean'; secret = 'boolean'; supported = 'boolean'
            displayName = 'text'; displayValue = 'text'
        } }
        PolicyResult { [ordered]@{
            policyKey = 'text'; status = 'status'; reason = 'text'; displayReason = 'text'; expected = 'Mapping[]'; observed = 'Observation[]'
            assigned = 'boolean'; assignmentsComplete = 'boolean'
        } }
        Policy { [ordered]@{
            key = 'text'; id = 'text'; name = 'text'; family = 'text'; policyType = 'text'; platform = 'text'
            template = 'Template'; osMin = 'text'; osMax = 'text'; enrollmentMode = 'text'
            windowsFamily = 'boolean'; osApplicabilityRule = 'OsApplicabilityRule'; unsupportedApplicability = 'boolean'
            assignments = 'Assignment[]'; settingsComplete = 'boolean'; assignmentsComplete = 'boolean'
            settingsTables = 'SettingTable[]'; settingsNote = 'text'
        } }
        SettingTable { [ordered]@{ title = 'text'; headers = 'text[]'; rows = 'SettingRow[]' } }
        SettingRow { [ordered]@{ cells = 'text[]' } }
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
        default { throw (Get-IdsText -Key 'text.unsupported_assessment_report_record_arg0' -Arguments @{ arg0 = ($Kind) }) }
    }
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -isnot [Collections.IDictionary] -and $InputObject -isnot [pscustomobject]) {
        throw (Get-IdsText -Key 'text.assessment_report_arg0_must_be_a_record' -Arguments @{ arg0 = ($Kind) })
    }
    $record = [ordered]@{}
    foreach ($field in $schema.Keys) {
        $type = $schema[$field]
        $value = Get-IdsReportMember $InputObject $field
        if ($type.EndsWith('[]')) {
            $itemType = $type.Substring(0, $type.Length - 2)
            $record[$field] = @(foreach ($item in $value) {
                if ($null -ne $item) { Copy-IdsReportField $item $itemType }
            })
            if ($Kind -cnotin @('SettingTable', 'SettingRow')) {
                $record[$field] = $record[$field] | Sort-Object { ConvertTo-Json -InputObject $_ -Depth 64 -Compress } -CaseSensitive
            }
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
    if (-not $valid) { throw (Get-IdsText -Key 'text.invalid_arg0_field_in_assessment_report_evidence' -Arguments @{ arg0 = ($Type) }) }
    return $Value
}

function Copy-IdsReportTypedValue {
    param($Value, [string]$ValueType, [bool]$Membership = $false)
    if ($ValueType -cnotin @('boolean', 'number', 'string', 'stringSet', 'numberSet')) {
        if ($null -eq $Value) { return $null }
        throw (Get-IdsText -Key 'text.unsupported_typed_assessment_report_value')
    }
    if ($null -eq $Value) { return $null }
    $type = if ($ValueType -ceq 'string' -or $ValueType -ceq 'stringSet') { 'text' }
        elseif ($ValueType -ceq 'numberSet') { 'number' } else { $ValueType }
    if ($Membership -or $ValueType.EndsWith('Set')) {
        if ($Value -isnot [Collections.IList]) { throw (Get-IdsText -Key 'text.assessment_report_set_value_must_be_an_array') }
        $items = @(foreach ($item in $Value) {
            if ($null -eq $item) { throw (Get-IdsText -Key 'text.assessment_report_set_cannot_contain_null') }
            Copy-IdsReportField $item $type
        })
        return ,@($items | Sort-Object { ConvertTo-Json -InputObject $_ -Compress } -CaseSensitive)
    }
    return Copy-IdsReportField $Value $type
}

function ConvertTo-IdsReportProjection {
    param([pscustomobject]$Result)
    if ($Result.schemaVersion -cne 1) { throw (Get-IdsText -Key 'text.unsupported_assessment_report_schemaversion_expected_1') }
    return Copy-IdsReportRecord $Result Result
}

function ConvertTo-IdsReportText {
    param([AllowNull()]$Value)
    # Entities neutralize both HTML and Markdown, including links, table/newline
    # injection and code fences. No imported content is emitted as markup.
    $text = if ($null -eq $Value) { (Get-IdsText -Key 'text.not_available') } else { [string]$Value }
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
    $lines.Add("| $(Get-IdsText 'text.field') | $(Get-IdsText 'text.evidence') |")
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

function Format-IdsReadableAssessmentEvidence {
    param($Expected, $Observed)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("| $(Get-IdsText 'text.evidence') | $(Get-IdsText 'text.setting') | $(Get-IdsText 'text.value') | $(Get-IdsText 'text.operator_policy') |")
    $lines.Add('| --- | --- | --- | --- |')
    foreach ($entry in @(@{ kind = 'Expected'; records = $Expected }, @{ kind = 'Configured'; records = $Observed })) {
        foreach ($record in $entry.records) {
            $name = if ($record.displayName) { $record.displayName }
                elseif ($record.property) { $record.property } else { $record.settingId }
            $value = if ($null -ne $record.displayValue) { $record.displayValue } else {
                $raw = if ($entry.kind -ceq 'Expected') { $record.expected } else { $record.value }
                ConvertTo-Json -InputObject $raw -Depth 64 -Compress
            }
            $scope = if ($entry.kind -ceq 'Expected') { $record.operator } else { $record.policyKey }
            $kindLabel = if ($entry.kind -ceq 'Expected') { Get-IdsText 'text.expected' } else { Get-IdsText 'text.configured' }
            $lines.Add("| $kindLabel | $(ConvertTo-IdsReportText $name) | $(ConvertTo-IdsReportText $value) | $(ConvertTo-IdsReportText $scope) |")
        }
    }
    return $lines -join "`n"
}

function ConvertTo-IdsProjectedAssessmentMarkdown {
    param($Result)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add((Get-IdsText -Key 'text.policy_configuration_alignment_assessment'))
    $lines.Add('')
    $lines.Add((Get-IdsText -Key 'text.this_is_configuration_alignment_not_effective_device_compliance_or_certification_assignments_are_evi'))
    $lines.Add((Get-IdsText -Key 'text.pack_origin_distinguishes_application_reviewed_bundled_resources_from_customer_imported_packs_import'))
    $lines.Add('')
    $lines.Add((Get-IdsText -Key 'text.missing_means_absent_not_configured_only_in_the_mapped_families_and_policy_types_read_completely_for'))
    $lines.Add('')
    $lines.Add((Get-IdsText -Key 'text.assessment_coverage_assessed_listed_controls_excluding_notapplicable_unknown_applicability_stays_in_'))
    $lines.Add('')
    $lines.Add((Get-IdsText 'report.status_legend' -Arguments @{
        aligned = (Get-IdsText 'text.aligned'); misaligned = (Get-IdsText 'text.misaligned')
        missing = (Get-IdsText 'text.missing'); potentialConflict = (Get-IdsText 'text.potential_conflict')
        notApplicable = (Get-IdsText 'text.not_applicable'); notAssessed = (Get-IdsText 'text.not_assessed')
    }))
    $lines.Add('')
    $lines.Add((Get-IdsText -Key 'text.run_identity_and_user_selected_context'))
    $lines.Add((Format-IdsReportRecord ([pscustomobject]@{
        schemaVersion = $Result.schemaVersion; runId = $Result.runId; generatedAt = $Result.generatedAt
        policySnapshotAt = $Result.policySnapshotAt; tenant = $Result.tenant; context = $Result.context
    })))
    foreach ($section in @(
        @{ title = (Get-IdsText -Key 'text.pack_identity_sources_and_coverage_boundaries'); field = 'packs'; heading = 'id' }
        @{ title = (Get-IdsText -Key 'text.assessment_coverage_and_configuration_alignment_summaries'); field = 'summaries'; heading = 'packId' }
        @{ title = (Get-IdsText -Key 'text.control_evidence'); field = 'controls'; heading = 'controlId' }
        @{ title = (Get-IdsText -Key 'text.source_policies_and_assignment_evidence'); field = 'policies'; heading = 'key' }
        @{ title = (Get-IdsText -Key 'text.collection_source_completeness'); field = 'sources'; heading = 'family' }
        @{ title = (Get-IdsText -Key 'text.collection_limitations'); field = 'collectionIssues'; heading = 'stage' }
    )) {
        $lines.Add('')
        $lines.Add("## $($section.title)")
        foreach ($record in $Result.($section.field)) {
            $lines.Add('')
            $lines.Add("### $(ConvertTo-IdsReportText $record.($section.heading))")
            if ($section.field -ceq 'controls') {
                $lines.Add("**$(ConvertTo-IdsReportText $record.title)**")
                $statusKeys = @{
                    aligned = 'text.aligned'; misaligned = 'text.misaligned'; missing = 'text.missing'
                    potentialConflict = 'text.potential_conflict'; notApplicable = 'text.not_applicable'; notAssessed = 'text.not_assessed'
                }
                $statusLabel = if ((Get-IdsLocale) -eq 'en-GB') { $record.status } else { Get-IdsText -Key $statusKeys[$record.status] }
                $reasonLabel = Get-IdsAssessmentDisplayReason $record.status $record.reason
                $lines.Add("$(ConvertTo-IdsReportText $statusLabel): $(ConvertTo-IdsReportText $reasonLabel)")
                $lines.Add('')
                $lines.Add((Format-IdsReadableAssessmentEvidence $record.expected $record.observed))
                $lines.Add('')
                $lines.Add("<details><summary>$(Get-IdsHtmlText 'text.exact_mappings_typed_values_and_assignment_evidence')</summary>")
                $lines.Add('')
                $lines.Add((Format-IdsReportRecord $record))
                $lines.Add('')
                $lines.Add('</details>')
            } elseif ($section.field -ceq 'policies') {
                $lines.Add("**$(ConvertTo-IdsReportText $record.name)**")
                $lines.Add((ConvertTo-IdsReportText $record.settingsNote))
                foreach ($table in $record.settingsTables) {
                    $lines.Add('')
                    if ($table.title) { $lines.Add("**$(ConvertTo-IdsReportText $table.title)**") }
                    $lines.Add('| ' + (($table.headers | ForEach-Object { ConvertTo-IdsReportText $_ }) -join ' | ') + ' |')
                    $lines.Add('| ' + (($table.headers | ForEach-Object { '---' }) -join ' | ') + ' |')
                    foreach ($row in $table.rows) {
                        $lines.Add('| ' + (($row.cells | ForEach-Object { ConvertTo-IdsReportText $_ }) -join ' | ') + ' |')
                    }
                }
                $lines.Add('')
                $lines.Add("<details><summary>$(Get-IdsHtmlText 'text.technical_policy_and_assignment_evidence')</summary>")
                $lines.Add('')
                $lines.Add((Format-IdsReportRecord ($record | Select-Object -Property * -ExcludeProperty settingsTables, settingsNote)))
                $lines.Add('')
                $lines.Add('</details>')
            } else {
                $lines.Add((Format-IdsReportRecord $record))
            }
        }
        if (@($Result.($section.field)).Count -eq 0) { $lines.Add((Get-IdsText -Key 'text.no_entries_supplied')) }
    }
    return (($lines -join "`n") + "`n")
}

function ConvertTo-IdsAssessmentMarkdown {
    param([Parameter(Mandatory)][pscustomobject]$Result, [string]$Locale = (Get-IdsLocale))
    $previousLocale = Get-IdsLocale
    try {
        Set-IdsLocale -Locale (Resolve-IdsLocale $Locale -Strict)
        return ConvertTo-IdsProjectedAssessmentMarkdown (ConvertTo-IdsReportProjection $Result)
    } finally { Set-IdsLocale $previousLocale }
}

function Get-IdsReportReparseTag {
    param([string]$Path)
    if (-not $IsWindows) { return 0 }
    if (-not ('Ids.ReportPathNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Ids {
    public static class ReportPathNative {
        [StructLayout(LayoutKind.Sequential)] struct AttributeTag { public uint Attributes, Tag; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int kind, out AttributeTag value, uint size);
        public static uint Tag(string path) {
            using (var file = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
                if (file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                AttributeTag value;
                if (!GetFileInformationByHandleEx(file, 9, out value, 8))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return value.Tag;
            }
        }
    }
}
'@
    }
    return [Ids.ReportPathNative]::Tag($Path)
}

function Test-IdsReportCloudTag {
    param([uint32]$Tag)
    # Cloud tags do not redirect the filesystem namespace; links and unknown tags stay blocked.
    return ($Tag -band 0xFFFF0FFFu) -eq 0x9000001Au -or $Tag -in @(0x80000015u, 0x80000021u)
}

function Get-IdsReportDirectoryAttributes {
    param([string]$Path)
    return [IO.File]::GetAttributes($Path)
}

function Assert-IdsReportDirectoryPath {
    param([string]$Path)
    $current = $Path
    while ($current) {
        try {
            $attributes = Get-IdsReportDirectoryAttributes $current
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if (-not (Test-IdsReportCloudTag (Get-IdsReportReparseTag $current))) {
                    throw (Get-IdsText 'error.report_linked_folder' -Arguments @{ path = $current })
                }
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
                throw (Get-IdsText -Key 'text.assessment_report_roots_must_be_directories')
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
        throw (Get-IdsText -Key 'text.assessment_report_roots_must_be_ordinary_fully_qualified_absolute_filesystem_paths')
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    foreach ($component in ($Path.Substring([IO.Path]::GetPathRoot($Path).Length) -split '[\\/]')) {
        if ($component -in @('', '.', '..')) { continue }
        if ($component -match '[<>:"|?*\x00-\x1f]' -or $component -match '[. ]$' -or
            $component -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
            throw (Get-IdsText -Key 'text.assessment_report_root_contains_an_ambiguous_filesystem_component')
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
                throw (Get-IdsText -Key 'text.assessment_installation_export_and_report_roots_must_not_overlap')
            }
        }
    }
}

function Write-IdsAssessmentReports {
    param(
        [Parameter(Mandatory)][pscustomobject]$Result,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ExportRoot,
        [string]$Locale = (Get-IdsLocale)
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
            [IO.Directory]::Exists($final) -or [IO.File]::Exists($final)) { throw (Get-IdsText -Key 'text.assessment_run_directory_already_exists') }
        [void][IO.Directory]::CreateDirectory($candidate)
        $stage = $candidate
        Assert-IdsReportDirectoryPath $stage
        $json = ConvertTo-Json -InputObject $projection -Depth 64
        Set-Content -LiteralPath (Join-Path $stage 'assessment.json') -Value $json -Encoding utf8 -NoNewline -ErrorAction Stop
        $markdown = ConvertTo-IdsAssessmentMarkdown -Result $projection -Locale $Locale
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
        throw [IO.IOException]::new((Get-IdsText -Key 'text.assessment_report_publication_failed_no_successful_report_pair_was_returned'), $_.Exception)
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
                Write-Warning (Get-IdsText -Key 'text.unable_to_clean_the_assessment_staging_directory_no_report_pair_was_published')
            }
        }
    }
}
