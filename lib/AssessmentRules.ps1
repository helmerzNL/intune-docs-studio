<#
    Pure configuration-alignment evaluation over validated packs and normalized
    snapshots. No collection, targeting resolution, file access, or device
    compliance claims belong here.

    Compare-IdsAssessmentValue returns assessed/aligned/reason with no coercion.
    Compare-IdsAssessment returns controls[] and per-pack summaries[]. Coverage
    counts aligned/misaligned/missing/potentialConflict over all listed controls
    except known exclusions; alignment counts aligned over those assessed four.
    Unknown applicability stays in the coverage denominator. Empty denominators
    return null. Inventory describes the pack's listed selection, not benchmark
    certification or discovered device scope.

    Android scope requires known enrollment context and policy metadata even
    for unrestricted controls. Incomplete sources block evaluation unless every
    failure is tied to an explicitly excluded policy; inventory/unknown failures
    still block it. Duplicate value equality uses the validated mapping's case
    semantics while preserving evidence from distinct policies.
#>

function Test-IdsRuleValueType {
    param($Value, [string]$Type)
    switch -CaseSensitive ($Type) {
        boolean { return $Value -is [bool] }
        string { return $Value -is [string] }
        number {
            return (($Value -is [byte] -or $Value -is [sbyte] -or
                $Value -is [int16] -or $Value -is [uint16] -or
                $Value -is [int32] -or $Value -is [uint32] -or
                $Value -is [int64] -or $Value -is [uint64] -or
                $Value -is [decimal] -or $Value -is [single] -or $Value -is [double]) -and
                -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value))
        }
        { $_ -cin @('stringSet', 'numberSet') } {
            if ($Value -isnot [Collections.IList]) { return $false }
            $scalar = $Type.Substring(0, $Type.Length - 3)
            foreach ($item in $Value) {
                if (-not (Test-IdsRuleValueType $item $scalar)) { return $false }
            }
            return $true
        }
        default { return $false }
    }
}

function ConvertTo-IdsRuleNumber {
    param($Value)
    # Compare invariant round-trip decimal representations, not PowerShell's
    # mixed-CLR numeric promotion (which can round distinct Int64/Decimal values
    # into the same Double). BigInteger alignment also handles finite exponents
    # outside Decimal's range without overflow or underflow.
    $format = if ($Value -is [double] -or $Value -is [single]) { 'R' }
        elseif ($Value -is [decimal]) { 'G29' } else { 'G' }
    $text = $Value.ToString($format, [Globalization.CultureInfo]::InvariantCulture)
    $parts = [regex]::Match($text, '\A(?<sign>-?)(?<whole>[0-9]+)(?:\.(?<fraction>[0-9]+))?(?:[eE](?<exponent>[+-]?[0-9]+))?\z')
    $fraction = $parts.Groups['fraction'].Value
    $exponent = if ($parts.Groups['exponent'].Success) { [int]$parts.Groups['exponent'].Value } else { 0 }
    return [pscustomobject]@{
        mantissa = [Numerics.BigInteger]::Parse(
            $parts.Groups['sign'].Value + $parts.Groups['whole'].Value + $fraction,
            [Globalization.CultureInfo]::InvariantCulture)
        exponent = $exponent - $fraction.Length
    }
}

function Compare-IdsRuleNumber {
    param($Left, $Right)
    $a = ConvertTo-IdsRuleNumber $Left
    $b = ConvertTo-IdsRuleNumber $Right
    $exponent = [Math]::Min($a.exponent, $b.exponent)
    $aValue = $a.mantissa * [Numerics.BigInteger]::Pow(10, $a.exponent - $exponent)
    $bValue = $b.mantissa * [Numerics.BigInteger]::Pow(10, $b.exponent - $exponent)
    return $aValue.CompareTo($bValue)
}

function Test-IdsRuleScalarEqual {
    param($Left, $Right, [bool]$CaseSensitive)
    if ($Left -is [string] -and $Right -is [string]) {
        $comparer = if ($CaseSensitive) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }
        return $comparer.Equals($Left, $Right)
    }
    if ((Test-IdsRuleValueType $Left number) -and (Test-IdsRuleValueType $Right number)) {
        return (Compare-IdsRuleNumber $Left $Right) -eq 0
    }
    return $Left -eq $Right
}

function Test-IdsRuleContains {
    param($Values, $Value, [bool]$CaseSensitive)
    foreach ($candidate in $Values) {
        if (Test-IdsRuleScalarEqual $candidate $Value $CaseSensitive) { return $true }
    }
    return $false
}

function Test-IdsRuleSetEqual {
    param($Left, $Right, [bool]$CaseSensitive)
    foreach ($item in $Left) {
        if (-not (Test-IdsRuleContains $Right $item $CaseSensitive)) { return $false }
    }
    foreach ($item in $Right) {
        if (-not (Test-IdsRuleContains $Left $item $CaseSensitive)) { return $false }
    }
    return $true
}

function Compare-IdsAssessmentValue {
    param([Parameter(Mandatory)][pscustomobject]$Mapping,
        [Parameter(Mandatory)][pscustomobject]$Observation)
    $result = [pscustomobject]@{ assessed = $false; aligned = $false; reason = '' }
    if ($Observation.secret -ne $false -or $Observation.supported -ne $true) {
        $result.reason = 'Unsupported or redacted setting evidence.'
    } elseif ($Observation.configured -ne $true) {
        $result.reason = 'Setting is not configured.'
    } elseif ($Mapping.caseSensitive -isnot [bool] -or
        $Mapping.operator -cnotin @('eq', 'ne', 'gte', 'lte', 'in', 'setEquals', 'containsAll') -or
        $Mapping.valueType -cnotin @('boolean', 'number', 'string', 'stringSet', 'numberSet')) {
        $result.reason = 'Unsupported mapping type, operator, or case sensitivity.'
    } elseif ($Observation.valueType -cne $Mapping.valueType -or
        -not (Test-IdsRuleValueType $Observation.value $Mapping.valueType)) {
        $result.reason = 'Observed value does not have the declared mapping type; coercion is not supported.'
    } else {
        $set = $Mapping.valueType -cin @('stringSet', 'numberSet')
        $op = $Mapping.operator
        if (($op -cin @('gte', 'lte') -and $Mapping.valueType -cne 'number') -or
            ($op -cin @('setEquals', 'containsAll') -and -not $set) -or
            ($op -ceq 'in' -and $set)) {
            $result.reason = 'Operator is incompatible with the mapping type.'
            return $result
        }

        $validExpected = if ($op -ceq 'in') {
            $valid = $Mapping.expected -is [Collections.IList] -and $Mapping.expected.Count -gt 0
            foreach ($item in $Mapping.expected) {
                if (-not (Test-IdsRuleValueType $item $Mapping.valueType)) { $valid = $false }
            }
            $valid
        } else { Test-IdsRuleValueType $Mapping.expected $Mapping.valueType }
        if (-not $validExpected) {
            $result.reason = 'Expected value does not have the required typed scalar or set shape.'
            return $result
        }
        $value = $Observation.value
        $expected = $Mapping.expected
        $case = $Mapping.caseSensitive
        $equal = if ($set) { Test-IdsRuleSetEqual $value $expected $case }
            else { Test-IdsRuleScalarEqual $value $expected $case }
        $result.aligned = switch -CaseSensitive ($op) {
            eq { $equal }
            ne { -not $equal }
            gte { (Compare-IdsRuleNumber $value $expected) -ge 0 }
            lte { (Compare-IdsRuleNumber $value $expected) -le 0 }
            in { Test-IdsRuleContains $expected $value $case }
            setEquals { $equal }
            containsAll {
                $contains = $true
                foreach ($item in $expected) {
                    if (-not (Test-IdsRuleContains $value $item $case)) { $contains = $false; break }
                }
                $contains
            }
        }
        $result.assessed = $true
        $result.reason = if ($result.aligned) { 'Configured value satisfies the rule.' } else { 'Configured value violates the rule.' }
    }
    return $result
}

function ConvertTo-IdsRuleOsVersion {
    param($Value)
    if ([string]$Value -cnotmatch '\A[0-9]+(\.[0-9]+){0,3}\z') { return $null }
    $components = @(([string]$Value).Split('.'))
    while ($components.Count -lt 4) { $components += '0' }
    $version = $null
    if ([version]::TryParse(($components -join '.'), [ref]$version)) { return $version }
    return $null
}

function Get-IdsRuleApplicability {
    param([string]$Platform, $Conditions, [hashtable]$Context, $Policy = $null)
    $unknown = [Collections.Generic.List[string]]::new()
    $excluded = [Collections.Generic.List[string]]::new()
    if (-not $Context.platforms -or @($Context.platforms).Count -eq 0) { $unknown.Add('Selected platform context is unknown.') }
    elseif ($Platform -cnotin $Context.platforms) { $excluded.Add('Selected platforms exclude this control.') }
    if ($null -ne $Policy) {
        if (-not $Policy.platform) { $unknown.Add('Policy platform applicability is unknown.') }
        elseif ($Policy.platform -cne $Platform) { $excluded.Add('Policy platform excludes this context.') }
    }
    $versionText = if ($Context.osVersions) { $Context.osVersions[$Platform] } else { $null }
    $version = ConvertTo-IdsRuleOsVersion $versionText
    foreach ($boundName in @('osMin', 'osMax')) {
        $boundText = $Conditions.$boundName
        if (-not $boundText) { continue }
        $bound = ConvertTo-IdsRuleOsVersion $boundText
        if ($null -eq $bound -or $null -eq $version) {
            $unknown.Add("OS version applicability ($boundName) is unknown.")
        } elseif (($boundName -ceq 'osMin' -and $version -lt $bound) -or
            ($boundName -ceq 'osMax' -and $version -gt $bound)) {
            $excluded.Add("OS version is outside $boundName.")
        }
    }
    $mode = if ($Context.enrollmentModes) { $Context.enrollmentModes[$Platform] } else { $null }
    # An empty control mode list is unrestricted, not evidence that the
    # selected Android context or a policy's enrollment scope is known.
    if ($Platform -ceq 'androidEnterprise' -and -not $mode) {
        $unknown.Add('Selected enrollment mode applicability is unknown.')
    }
    if (@($Conditions.enrollmentModes).Count -gt 0) {
        if (-not $mode) { $unknown.Add('Enrollment mode applicability is unknown.') }
        elseif ($mode -cnotin $Conditions.enrollmentModes) { $excluded.Add('Selected enrollment mode is excluded.') }
    }
    if ($null -ne $Policy -and $Platform -ceq 'androidEnterprise') {
        if (-not $Policy.enrollmentMode) { $unknown.Add('Policy enrollment mode applicability is unknown.') }
        elseif ($mode -and $Policy.enrollmentMode -cne $mode) { $excluded.Add('Policy enrollment mode excludes this context.') }
    }
    if ($excluded.Count -gt 0) { return [pscustomobject]@{ status = 'notApplicable'; reason = $excluded -join ' ' } }
    if ($unknown.Count -gt 0) { return [pscustomobject]@{ status = 'notAssessed'; reason = $unknown -join ' ' } }
    return [pscustomobject]@{ status = 'applicable'; reason = 'Applicability established by assessment context and explicit policy metadata.' }
}

function Test-IdsRuleObservationMatch {
    param($Mapping, $Observation)
    return ($Mapping.family -ceq $Observation.family -and
        $Mapping.settingId -ceq $Observation.settingId -and
        $Mapping.property -ceq $Observation.property -and
        (-not $Mapping.instancePath -or $Mapping.instancePath -ceq $Observation.instancePath))
}

function Test-IdsRuleObservationIdentity {
    param($Left, $Right, [switch]$AcrossPolicies)
    return (($AcrossPolicies -or $Left.policyKey -ceq $Right.policyKey) -and
        $Left.family -ceq $Right.family -and $Left.settingId -ceq $Right.settingId -and
        $Left.property -ceq $Right.property -and $Left.instancePath -ceq $Right.instancePath)
}

function Test-IdsRuleObservationEqual {
    param($Left, $Right, [bool]$CaseSensitive = $true)
    if ($Left.valueType -cne $Right.valueType -or
        $Left.configured -ne $Right.configured -or $Left.supported -ne $Right.supported -or
        $Left.secret -ne $Right.secret) { return $false }
    if ($Left.valueType -cin @('stringSet', 'numberSet')) {
        return Test-IdsRuleSetEqual $Left.value $Right.value $CaseSensitive
    }
    return Test-IdsRuleScalarEqual $Left.value $Right.value $CaseSensitive
}

function Copy-IdsRuleObservation {
    param($Observation)
    $value = if ($Observation.secret -eq $true -or $Observation.supported -ne $true) { $null }
        elseif ($Observation.value -is [Collections.IList]) { ,@($Observation.value) }
        else { $Observation.value }
    return [pscustomobject]@{
        policyKey = $Observation.policyKey; family = $Observation.family
        settingId = $Observation.settingId; property = $Observation.property
        instancePath = $Observation.instancePath; valueType = $Observation.valueType
        value = $value; configured = $Observation.configured
        secret = $Observation.secret; supported = $Observation.supported
    }
}

function Compare-IdsAssessment {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packs,
        [Parameter(Mandatory)][pscustomobject]$Snapshot,
        [Parameter(Mandatory)][hashtable]$Context)
    $controls = [Collections.Generic.List[object]]::new()
    $summaries = [Collections.Generic.List[object]]::new()
    $policies = @($Snapshot.policies | Sort-Object key -CaseSensitive)
    $observations = @($Snapshot.observations | Sort-Object policyKey, family, settingId, property, instancePath, valueType,
        @{ Expression = { if ($_.secret -eq $false -and $_.supported -eq $true) { ConvertTo-Json -InputObject $_.value -Compress -Depth 4 } } } -CaseSensitive)
    foreach ($pack in ($Packs | Sort-Object id, version, platform, profile -CaseSensitive)) {
        $packStart = $controls.Count
        foreach ($control in ($pack.controls | Sort-Object id -CaseSensitive)) {
            $observed = [Collections.Generic.List[object]]::new()
            $policyResults = [Collections.Generic.List[object]]::new()
            $evaluations = [Collections.Generic.List[object]]::new()
            $limitations = [Collections.Generic.List[string]]::new()
            $applicability = Get-IdsRuleApplicability $pack.platform $control.applicability $Context
            if ($applicability.status -ceq 'notAssessed') { $limitations.Add($applicability.reason) }
            if ($control.manualReason) { $limitations.Add([string]$control.manualReason) }
            elseif (@($control.mappings).Count -eq 0) { $limitations.Add('No supported automated mapping is available.') }
            foreach ($family in @($control.mappings.family | Sort-Object -Unique -CaseSensitive)) {
                $sources = @($Snapshot.sources | Where-Object {
                    $_.family -ceq $family -and (-not $_.platform -or $_.platform -ceq $pack.platform)
                })
                $incomplete = $sources.Count -eq 0
                foreach ($source in @($sources | Where-Object complete -NE $true)) {
                    if ($null -eq $source.errors -or @($source.errors).Count -eq 0) { $incomplete = $true }
                    foreach ($error in $source.errors) {
                        # A source retains all collection failures. Only known,
                        # policy-scoped settings/metadata failures can be
                        # dismissed after explicit applicability exclusion.
                        $failedPolicies = @($policies | Where-Object {
                            $_.key -ceq $error.policyKey -and $_.family -ceq $family
                        })
                        if ($error.family -cne $family -or $error.stage -cnotin @('settings', 'template') -or
                            $failedPolicies.Count -ne 1) { $incomplete = $true; continue }
                        $failedPolicy = $failedPolicies[0]
                        $failedScope = Get-IdsRuleApplicability $pack.platform @{
                            osMin = $failedPolicy.osMin; osMax = $failedPolicy.osMax; enrollmentModes = @()
                        } $Context $failedPolicy
                        if ($failedScope.status -cne 'notApplicable') { $incomplete = $true }
                    }
                }
                if ($incomplete) {
                    $limitations.Add("Relevant source '$family' is incomplete or unreported.")
                }
            }
            foreach ($policy in $policies) {
                if ($applicability.status -ceq 'notApplicable') { continue }
                $mappings = @($control.mappings | Where-Object {
                    $_.family -ceq $policy.family -and $policy.policyType -cin $_.policyTypes
                })
                if ($mappings.Count -eq 0) { continue }
                $policyScope = Get-IdsRuleApplicability $pack.platform @{
                    osMin = $policy.osMin; osMax = $policy.osMax; enrollmentModes = @()
                } $Context $policy
                if ($policyScope.status -ceq 'notApplicable') { continue }
                if ($applicability.status -ceq 'notAssessed') {
                    $policyScope = [pscustomobject]@{ status = 'notAssessed'; reason = $applicability.reason }
                }
                $policyObserved = [Collections.Generic.List[object]]::new()
                $comparisons = [Collections.Generic.List[object]]::new()
                $contradictory = $false
                foreach ($observation in $observations) {
                    if ($observation.policyKey -cne $policy.key) { continue }
                    $matches = @($mappings | Where-Object { Test-IdsRuleObservationMatch $_ $observation })
                    if ($matches.Count -eq 0) { continue }
                    $duplicate = $false
                    foreach ($existing in $policyObserved) {
                        if (Test-IdsRuleObservationIdentity $existing $observation) {
                            if (Test-IdsRuleObservationEqual $existing $observation $matches[0].caseSensitive) { $duplicate = $true; break }
                            $contradictory = $true
                        }
                    }
                    if ($duplicate) { continue }
                    $evidence = Copy-IdsRuleObservation $observation
                    $policyObserved.Add($evidence)
                    $observed.Add($evidence)
                    # Validated alternatives describe one atomic check. Evaluate
                    # each observation once; never combine repeated instances.
                    if ($observation.configured -eq $true -or $observation.supported -ne $true -or $observation.secret -ne $false) {
                        $comparison = Compare-IdsAssessmentValue $matches[0] $observation
                        $comparisons.Add($comparison)
                        $evaluations.Add([pscustomobject]@{ observation = $evidence; mapping = $matches[0]; comparison = $comparison })
                    }
                }
                $configured = @($policyObserved | Where-Object configured -EQ $true)
                $status = if ($contradictory -or $policyScope.status -ceq 'notAssessed' -or $policy.settingsComplete -ne $true -or
                    @($comparisons | Where-Object assessed -EQ $false).Count -gt 0) { 'notAssessed' }
                    elseif ($configured.Count -eq 0) { 'missing' }
                    elseif (@($comparisons | Where-Object aligned -EQ $false).Count -gt 0) { 'misaligned' }
                    else { 'aligned' }
                $reason = switch ($status) {
                    notAssessed {
                        if ($contradictory) { 'Contradictory duplicate evidence for one policy/setting/path identity.' }
                        elseif ($policyScope.status -ceq 'notAssessed') { $policyScope.reason }
                        else { 'Incomplete settings read, unsupported, redacted, or untyped setting evidence.' }
                    }
                    missing { 'Mapped setting is absent or not configured in this policy.' }
                    misaligned { 'Configured value violates the rule.' }
                    aligned { 'Configured values satisfy the rule; this is not device compliance.' }
                }
                if ($status -ceq 'notAssessed') {
                    foreach ($comparison in $comparisons) {
                        if (-not $comparison.assessed -or -not $comparison.aligned) { $reason += " $($comparison.reason)" }
                    }
                    $limitations.Add("Policy '$($policy.key)': $reason")
                }
                $assigned = if ($policy.assignmentsComplete -eq $true) { @($policy.assignments).Count -gt 0 } else { $null }
                if ($assigned -eq $false) { $reason += ' Policy is unassigned; matching configuration does not establish device reach.' }
                if ($null -eq $assigned) { $reason += ' Assignment evidence is incomplete; device reach is unknown.' }
                $policyResults.Add([pscustomobject]@{
                    policyKey = $policy.key; status = $status; reason = $reason
                    expected = @($mappings); observed = $policyObserved.ToArray()
                    assigned = $assigned; assignmentsComplete = $policy.assignmentsComplete
                })
            }
            $conflict = $false
            for ($i = 0; $i -lt $evaluations.Count; $i++) {
                $left = $evaluations[$i]
                if ($left.observation.configured -ne $true -or $left.observation.secret -ne $false -or
                    $left.observation.supported -ne $true) { continue }
                for ($j = $i + 1; $j -lt $evaluations.Count; $j++) {
                    $right = $evaluations[$j]
                    # Different selectors are declared equivalent by the pack.
                    # Repeated occurrences of the same selector remain scoped
                    # to their exact instance path.
                    $alternativeSelector = $left.mapping.family -cne $right.mapping.family -or
                        $left.mapping.settingId -cne $right.mapping.settingId -or
                        $left.mapping.property -cne $right.mapping.property
                    if ($right.observation.configured -eq $true -and $right.observation.secret -eq $false -and
                        $right.observation.supported -eq $true -and
                        $left.observation.policyKey -cne $right.observation.policyKey -and
                        ($alternativeSelector -or (Test-IdsRuleObservationIdentity $left.observation $right.observation -AcrossPolicies)) -and
                        -not (Test-IdsRuleObservationEqual $left.observation $right.observation $left.mapping.caseSensitive)) {
                        $conflict = $true
                    }
                }
            }
            $mismatch = @($evaluations | Where-Object { $_.comparison.assessed -and -not $_.comparison.aligned }).Count -gt 0
            $status = if ($applicability.status -ceq 'notApplicable') { 'notApplicable' }
                elseif ($limitations.Count -gt 0) { 'notAssessed' }
                elseif ($conflict) { 'potentialConflict' }
                elseif (@($policyResults | Where-Object status -EQ misaligned).Count -gt 0) { 'misaligned' }
                elseif (@($observed | Where-Object configured -EQ $true).Count -eq 0) { 'missing' }
                else { 'aligned' }
            $reason = switch ($status) {
                notApplicable { $applicability.reason }
                notAssessed { $limitations -join ' ' }
                potentialConflict { 'Differing configured values across policies; potential conflict only, not proof of overlapping targeting or an Intune conflict.' }
                misaligned { 'Configured values violate the rule.' }
                missing { 'Mapped setting is absent or not configured across relevant sources.' }
                aligned { 'Configured values satisfy the rule; this is configuration alignment, not device compliance.' }
            }
            if ($status -ceq 'notAssessed') {
                if ($conflict) { $reason += ' Observed potential conflict: differing cross-policy values; targeting overlap is not established.' }
                if ($mismatch) { $reason += ' Observed configured values violate the rule.' }
            }
            $references = @($pack.sources | Where-Object { $_.id -cin $control.sourceIds } | ForEach-Object {
                [pscustomobject]@{ id = $_.id; url = $_.url; revision = $_.revision; retrievedOn = $_.retrievedOn; reference = $control.reference }
            })
            $controls.Add([pscustomobject]@{
                packId = $pack.id; packVersion = $pack.version; platform = $pack.platform; profile = $pack.profile
                controlId = $control.id; title = $control.title; status = $status; reason = $reason
                expected = @($control.mappings); observed = $observed.ToArray()
                policyResults = $policyResults.ToArray(); references = $references
            })
        }
        $counts = [ordered]@{
            aligned = 0; misaligned = 0; missing = 0; potentialConflict = 0
            notApplicable = 0; notAssessed = 0
        }
        for ($index = $packStart; $index -lt $controls.Count; $index++) { $counts[$controls[$index].status]++ }
        $assessed = $counts.aligned + $counts.misaligned + $counts.missing + $counts.potentialConflict
        $denominator = $controls.Count - $packStart - $counts.notApplicable
        $coverage = if ($denominator -gt 0) { [Math]::Round(100.0 * $assessed / $denominator, 1) } else { $null }
        $alignment = if ($assessed -gt 0) { [Math]::Round(100.0 * $counts.aligned / $assessed, 1) } else { $null }
        $summaries.Add([pscustomobject]@{
            packId = $pack.id; platform = $pack.platform; profile = $pack.profile
            inventory = $pack.coverage.inventory; counts = [pscustomobject]$counts
            assessed = $assessed; coverageDenominator = $denominator
            coveragePercent = $coverage; alignmentPercent = $alignment
        })
    }
    return [pscustomobject]@{ controls = $controls.ToArray(); summaries = $summaries.ToArray() }
}
