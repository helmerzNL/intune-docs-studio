. (Join-Path $PSScriptRoot 'Localization.ps1')

function ConvertTo-IdsReferencePacks {
    param($Snapshot)
    $normalized = ConvertTo-IdsAssessmentSnapshot $Snapshot.collection
    $skipped = [Collections.Generic.List[object]]::new()
    if (-not $Snapshot.capturedAt) {
        return @{ packs = @(); skipped = @(@{ entry = (Get-IdsText -Key 'text.policy_set'); reason = (Get-IdsText -Key 'text.original_collection_date_is_unknown_a_dated_reference_source_cannot_be_established') }); skippedCount = 1; ignored = 0 }
    }
    $retrievedOn = ([datetimeoffset]::Parse($Snapshot.capturedAt)).UtcDateTime.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $groups = @{}
    foreach ($policy in $normalized.policies) {
        $original = @($Snapshot.collection.policies | Where-Object key -CEQ $policy.key)[0]
        $platform = $original.platform
        $observations = @($normalized.observations | Where-Object policyKey -CEQ $policy.key)
        if (-not $policy.settingsComplete -or $platform -cnotin @('windows11', 'macos', 'iosIpados', 'androidEnterprise') -or
            @($normalized.sources | Where-Object { $_.family -ceq $policy.family -and $_.platform -ceq $platform -and -not $_.complete }).Count) {
            $skipped.Add(@{ entry = $policy.name; reason = (Get-IdsText -Key 'text.incomplete_unsupported_or_secret_policy_evidence_no_reference_checks_were_generated') })
            continue
        }
        if (-not $groups.ContainsKey($platform)) { $groups[$platform] = @{} }
        foreach ($observation in $observations) {
            if (-not $observation.configured -or -not $observation.supported -or $observation.secret -or -not $observation.valueType) {
                $skipped.Add(@{ entry = $policy.name; reason = (Get-IdsText -Key 'text.unconfigured_unsupported_or_secret_setting_was_skipped') }); continue
            }
            $path = if ($policy.family -eq 'admx') { $observation.instancePath } else { $null }
            $mapping = [ordered]@{
                family = $policy.family; policyTypes = @($policy.policyType); settingId = $observation.settingId
                property = $observation.property; instancePath = $path; valueType = $observation.valueType
                operator = $(if ($observation.valueType -in @('stringSet', 'numberSet')) { 'setEquals' } else { 'eq' })
                expected = $observation.value; caseSensitive = $true
            }
            $selector = "$($policy.family)|$($policy.policyType)|$($observation.settingId)|$($observation.property)|$path"
            $valueKey = Get-IdsBuildKitValueKey $observation.valueType $observation.value
            $candidates = $groups[$platform]
            if ($candidates.ContainsKey($selector)) {
                if ($candidates[$selector].valueKey -cne $valueKey) {
                    $candidates[$selector].conflict = $true
                    $skipped.Add(@{ entry = $selector; reason = (Get-IdsText -Key 'text.reference_policies_contain_different_configured_values_for_this_mapping_skipped_rather_than_choosing') })
                }
                continue
            }
            $title = $observation.settingId
            if ($observation.property) {
                $config = [ordered]@{}; $config[$observation.property] = $observation.value
                $table = Format-IdsTemplateSettings -Config ([pscustomobject]$config) -AsData
                $title = $table.rows[0].cells[0]
            }
            foreach ($raw in $original.rawSettings) {
                foreach ($definition in (Get-IdsAssessmentMember $raw 'settingDefinitions')) {
                    if ($definition.id -ceq $observation.settingId -and $definition.displayName) { $title = $definition.displayName }
                }
            }
            $candidates[$selector] = @{ mapping = $mapping; title = $title; valueKey = $valueKey; conflict = $false }
        }
    }
    $packs = [Collections.Generic.List[byte[]]]::new()
    foreach ($platform in $groups.Keys | Sort-Object -CaseSensitive) {
        $controls = @(foreach ($selector in $groups[$platform].Keys | Sort-Object -CaseSensitive) {
            $candidate = $groups[$platform][$selector]
            if ($candidate.conflict) { continue }
            $id = (Get-IdsBuildKitSha256 ([Text.Encoding]::UTF8.GetBytes($selector))).Substring(0, 24)
            [ordered]@{
                id = "ref-$id"; title = $candidate.title; sourceIds = @('customer-reference')
                reference = 'Configured value from a customer-supplied policy set; partial mapping coverage, not certification.'
                applicability = [ordered]@{ osMin = $null; osMax = $null; enrollmentModes = @() }
                manualReason = $null; mappings = @($candidate.mapping)
            }
        })
        if ($controls.Count -eq 0) { continue }
        $provenance = [ordered]@{ environment = $Snapshot.tenant.name; capturedAt = $Snapshot.capturedAt; controls = $controls }
        $fingerprint = Get-IdsBuildKitSha256 (ConvertTo-IdsBuildKitJsonBytes $provenance)
        $pack = [ordered]@{
            schemaVersion = 1L; id = "custom-reference-$platform-$($fingerprint.Substring(0, 16))"; version = '1.0.0'
            framework = 'Custom reference'; frameworkVersion = "$($Snapshot.tenant.name) - $retrievedOn"; classification = 'baseline'
            platform = $platform; profile = 'Imported reference configuration'
            sourceRevision = "Reference configuration and provenance SHA-256 $fingerprint"
            sources = @([ordered]@{ id = 'customer-reference'; url = 'https://example.invalid/customer-policy-reference'
                revision = "Reference configuration and provenance SHA-256 $fingerprint"; retrievedOn = $retrievedOn })
            coverage = [ordered]@{ inventory = 'partial'; totalSourceControls = $null }; controls = $controls
        }
        $bytes = ConvertTo-IdsBuildKitJsonBytes $pack
        [void](Read-IdsBaselinePack $bytes)
        $packs.Add($bytes)
    }
    return @{ packs = $packs.ToArray(); skipped = $skipped.ToArray(); skippedCount = $skipped.Count; ignored = 0 }
}

function Remove-IdsImportedPack {
    param([hashtable]$State, [string]$Root, [string]$Identity, [bool]$Confirmed)
    if (-not $Confirmed) { throw (Get-IdsText -Key 'text.confirm_removal_from_the_local_pack_library') }
    if (Test-IdsWorkActive $State) { throw (Get-IdsText -Key 'text.wait_for_imports_and_active_runs_before_removing_a_pack') }
    $catalog = Get-IdsAssessmentCatalog $State $Root
    $matches = @($catalog.packs | Where-Object { "$($_.id)@$($_.version)#$($_.sha256)" -ceq $Identity })
    if ($matches.Count -ne 1 -or $matches[0].origin -cne 'imported') { throw (Get-IdsText -Key 'text.only_an_existing_imported_pack_identity_can_be_removed_bundled_packs_are_protected') }
    $pack = $matches[0]
    $storage = $State.Config.ImportedPackRoot
    Assert-IdsPackNoReparsePath $storage
    $lock = [IO.FileStream]::new((Join-Path $storage '.import.lock'), [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    try {
        $targets = @(foreach ($file in Get-ChildItem -LiteralPath $storage -Filter '*.json' -File -ErrorAction Stop) {
            Assert-IdsPackNoReparsePath $file.FullName
            if ($file.Length -le 10MB) {
                $bytes = [IO.File]::ReadAllBytes($file.FullName)
                if ((Get-IdsBuildKitSha256 $bytes) -cne $pack.sha256) { continue }
                $candidate = Read-IdsBaselinePack $bytes
                if ($candidate.sha256 -ceq $pack.sha256 -and $candidate.id -ceq $pack.id -and $candidate.version -ceq $pack.version) { $file.FullName }
            }
        })
        if (-not $targets.Count) { throw (Get-IdsText -Key 'text.imported_pack_bytes_changed_reload_the_library') }
        foreach ($target in $targets) { [IO.File]::Delete($target) }
    } finally { $lock.Dispose() }
    return @{ removed = $Identity }
}
