. (Join-Path $PSScriptRoot 'Localization.ps1')

function Test-IdsWorkActive {
    param([hashtable]$State)
    return [bool]($State.Export.running -or $State.Assessment.running -or $State.Browser.running -or
        ($State.Job -and -not $State.Job.handle.IsCompleted) -or
        ($State.Browser.job -and -not $State.Browser.job.handle.IsCompleted) -or
        ($State.Assessment.job -and -not $State.Assessment.job.handle.IsCompleted) -or
        $State.Policies.running -or ($State.Policies.job -and -not $State.Policies.job.handle.IsCompleted) -or
        $State.PolicyTransfer.running -or $State.PackImport.running)
}

function Initialize-IdsAssessment {
    param([hashtable]$State)
    if (-not $State.Assessment) {
        $State.Assessment = [hashtable]::Synchronized(@{
            running = $false; done = $false; error = $null; percent = 0; phase = ''
            epoch = 0L; resultEpoch = $null; runId = $null; result = $null
            reportPaths = $null; partial = $false; job = $null
        })
    }
}

function Get-IdsAssessmentCatalog {
    param([hashtable]$State, [string]$Root)
    $imported = $State.Config.ImportedPackRoot
    if (-not $imported) { throw (Get-IdsText -Key 'text.local_imported_pack_directory_is_not_configured') }
    return Get-IdsBaselinePacks -BundledRoot (Join-Path $Root 'baselines') -ImportedRoot $imported
}

function Assert-IdsAssessmentFields {
    param($Value, [string[]]$Allowed, [string[]]$Required = @())
    if ($Value -isnot [Collections.IDictionary]) { throw (Get-IdsText -Key 'text.assessment_input_must_be_an_object') }
    foreach ($key in $Value.Keys) {
        if ($key -cnotin $Allowed) { throw (Get-IdsText -Key 'text.unknown_assessment_input_field') }
    }
    foreach ($key in $Required) {
        if ($key -cnotin @($Value.Keys)) { throw (Get-IdsText -Key 'text.assessment_arg0_is_required' -Arguments @{ arg0 = ($key) }) }
    }
}

function Resolve-IdsAssessmentOptions {
    param([hashtable]$State, [hashtable]$Options, [string]$Root)
    Assert-IdsAssessmentFields $Options @('packIds', 'context', 'outputPath') @('packIds', 'context', 'outputPath')
    if ($Options.packIds -isnot [array] -or $Options.packIds.Count -lt 1 -or $Options.packIds.Count -gt 64) {
        throw (Get-IdsText -Key 'text.select_between_1_and_64_pack_identities')
    }
    $context = $Options.context
    Assert-IdsAssessmentFields $context @('platforms', 'osVersions', 'enrollmentModes') @('platforms')
    $platforms = @('windows11', 'macos', 'iosIpados', 'androidEnterprise')
    if ($context.platforms -isnot [array] -or $context.platforms.Count -lt 1 -or $context.platforms.Count -gt 4) {
        throw (Get-IdsText -Key 'text.select_between_1_and_4_platforms')
    }
    foreach ($platform in $context.platforms) {
        if ($platform -isnot [string] -or $platform -cnotin $platforms) { throw (Get-IdsText -Key 'text.unknown_assessment_platform') }
    }
    if (@($context.platforms | Select-Object -Unique).Count -ne $context.platforms.Count) { throw (Get-IdsText -Key 'text.duplicate_assessment_platform') }
    $snapshot = @{ platforms = @($context.platforms); osVersions = @{}; enrollmentModes = @{} }
    foreach ($field in 'osVersions', 'enrollmentModes') {
        if ($null -eq $context[$field]) { continue }
        Assert-IdsAssessmentFields $context[$field] $(if ($field -eq 'osVersions') { $platforms } else { @('androidEnterprise', 'iosIpados') })
        foreach ($key in $context[$field].Keys) {
            $value = $context[$field][$key]
            if ($value -isnot [string] -or $value.Length -gt 128) { throw (Get-IdsText -Key 'text.invalid_assessment_applicability_value') }
            if ($field -eq 'osVersions' -and -not (ConvertTo-IdsRuleOsVersion $value)) { throw (Get-IdsText -Key 'text.invalid_assessment_os_version') }
            if ($field -eq 'enrollmentModes') {
                $modes = if ($key -ceq 'iosIpados') { @('personallyOwned', 'corporateOwned') }
                    else { @('workProfile', 'fullyManaged', 'dedicated', 'corporateOwnedWorkProfile') }
                if ($value -cnotin $modes) { throw (Get-IdsText -Key 'text.invalid_arg0_enrollment_ownership_mode' -Arguments @{ arg0 = ($key) }) }
            }
            $snapshot[$field][$key] = $value
        }
    }
    if ($Options.outputPath -isnot [string]) { throw (Get-IdsText -Key 'text.assessment_outputpath_must_be_an_absolute_path') }
    $output = Get-IdsReportCanonicalRoot $Options.outputPath
    $install = Get-IdsReportCanonicalRoot $Root
    $export = Get-IdsReportCanonicalRoot $State.Config.OutputPath
    Assert-IdsReportDistinctRoots @($output, $install, $export)
    $catalog = Get-IdsAssessmentCatalog $State $Root
    $selected = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($identity in $Options.packIds) {
        if ($identity -isnot [string] -or $identity.Length -gt 512 -or -not $seen.Add($identity)) { throw (Get-IdsText -Key 'text.invalid_or_duplicate_pack_identity') }
        $matches = @($catalog.packs | Where-Object { "$($_.id)@$($_.version)#$($_.sha256)" -ceq $identity })
        if ($matches.Count -eq 0) { throw (Get-IdsText -Key 'text.unknown_pack_identity_or_changed_sha_256_hash_reload_the_catalog') }
        $pack = $matches[0]
        if ($pack.platform -cnotin $snapshot.platforms) { throw (Get-IdsText -Key 'text.selected_pack_does_not_match_the_platform_context') }
        # These are fresh validated objects, never references retained by the caller
        # or re-read by the worker after admission.
        $selected.Add($pack)
    }
    foreach ($platform in $snapshot.platforms) {
        if ($platform -cnotin @($selected | ForEach-Object platform)) { throw (Get-IdsText -Key 'text.every_selected_platform_requires_an_applicable_pack') }
    }
    return @{ packs = $selected.ToArray(); context = $snapshot; outputPath = $output; exportRoot = $export }
}

function Start-IdsAssessmentJob {
    param([hashtable]$State, [hashtable]$Options, [string]$Root)
    if (Test-IdsWorkActive $State) { return $false }
    if (-not $State.Auth -and -not $State.Policies) { throw (Get-IdsText -Key 'text.load_or_import_a_policy_set_first') }
    if ($State.Browser.running) { return $false }
    Initialize-IdsAssessment $State
    Clear-IdsAssessmentJob $State
    if ($State.Assessment.job) { return $false }
    $resolved = Resolve-IdsAssessmentOptions $State $Options $Root
    $resolved.Locale = Get-IdsLocale
    $State.Assessment.locale = $resolved.Locale
    $loadedPolicies = if ($State.Policies) { Get-IdsLoadedPolicies $State } else { $null }
    $assessment = $State.Assessment
    $epoch = $assessment.epoch
    $runId = [guid]::NewGuid().ToString('N')
    $assessment.done = $false
    $assessment.error = $null
    $assessment.result = $null
    $assessment.resultEpoch = $epoch
    $assessment.reportPaths = $null
    $assessment.partial = $false
    $assessment.percent = 0
    $assessment.phase = (Get-IdsText -Key 'text.starting')
    $assessment.runId = $runId
    $assessment.running = $true
    # Admission and identity replacement are serialized in the HTTP loop.
    # A worker has its own holder so refresh cannot replace another session.
    $auth = @{}
    foreach ($key in $State.Auth.Keys) { $auth[$key] = $State.Auth[$key] }
    $worker = {
        param($Root, $State, $Options, $Auth, $Epoch, $RunId, $LoadedPolicies)
        $ErrorActionPreference = 'Stop'
        $a = $State.Assessment
        try {
            . (Join-Path $Root 'lib\Localization.ps1')
            Set-IdsLocale -Locale $Options.Locale
            foreach ($module in 'Auth', 'Graph', 'Render', 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules', 'AssessmentReports', 'PolicyInventory') {
                . (Join-Path $Root "lib\$module.ps1")
            }
            if (-not $LoadedPolicies) {
                if ($Auth.transport -eq 'mggraph') { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop }
                Initialize-IdsGraph -StateHolder @{ Auth = $Auth }
            }
            if ($LoadedPolicies) {
                $tenants = @(@{ id = $LoadedPolicies.tenant.id; displayName = $LoadedPolicies.tenant.name })
                $a.phase = (Get-IdsText -Key 'text.using_loaded_policies'); $a.percent = 10
                $collection = Select-IdsPolicyCollection $LoadedPolicies $Options.packs $Options.context
            } else {
            $a.phase = (Get-IdsText -Key 'text.authenticating')
            try {
                $organization = Invoke-IdsGraph -Path '/organization?$select=id,displayName' -Version 'v1.0'
                $tenants = @(Get-IdsAssessmentMember $organization 'value')
            } catch {
                # Organization display metadata is not a new consent requirement.
                # Only denied/unavailable metadata may fall back to the signed-in
                # tenant identity; authentication and transport failures still fail.
                if ($_.Exception.StatusCode -notin @(403, 404) -or -not $Auth.tenant_id) { throw }
                $tenants = @(@{ id = $Auth.tenant_id; displayName = '' })
            }
            if ($tenants.Count -ne 1 -or -not $tenants[0].id) { throw (Get-IdsText -Key 'text.cannot_establish_authenticated_tenant') }
            if ($Auth.tenant_id -and $Auth.tenant_id -ne $tenants[0].id) { throw (Get-IdsText -Key 'text.authenticated_tenant_does_not_match_the_session') }
            $a.phase = (Get-IdsText -Key 'text.collecting'); $a.percent = 10
            $collection = Get-IdsAssessmentCollection -Packs $Options.packs -Context $Options.context
            if (@($collection.issues | Where-Object { $_.statusCode -eq 401 -or $_.authenticationFailure }).Count) {
                throw (Get-IdsText -Key 'text.assessment_authentication_failed')
            }
            }
            $a.phase = (Get-IdsText -Key 'text.normalizing'); $a.percent = 50
            $snapshot = ConvertTo-IdsAssessmentSnapshot -Collection $collection
            Add-IdsAssessmentPolicyPresentation -Collection $collection -Snapshot $snapshot
            $a.phase = (Get-IdsText -Key 'text.evaluating'); $a.percent = 65
            $evaluation = Compare-IdsAssessment -Packs $Options.packs -Snapshot $snapshot -Context $Options.context
            Add-IdsAssessmentEvidencePresentation -Collection $collection -Evaluation $evaluation
            $result = ConvertTo-IdsReportProjection ([pscustomobject]@{
                schemaVersion = 1; runId = $RunId; generatedAt = [datetime]::UtcNow.ToString('o')
                policySnapshotAt = $LoadedPolicies.capturedAt
                policySource = $LoadedPolicies.source
                tenant = @{ id = [string]$tenants[0].id; name = [string]$tenants[0].displayName }
                context = $Options.context; packs = @($Options.packs)
                summaries = @($evaluation.summaries); controls = @($evaluation.controls)
                policies = @($snapshot.policies); collectionIssues = @($snapshot.issues); sources = @($snapshot.sources)
            })
            if ($a.epoch -ne $Epoch -or $a.runId -ne $RunId) { throw (Get-IdsText -Key 'text.assessment_session_expired') }
            $a.phase = (Get-IdsText -Key 'text.writing_reports'); $a.percent = 85
            $paths = Write-IdsProjectedAssessmentReports -Projection $result -OutputPath $Options.outputPath -InstallRoot $Root -ExportRoot $Options.exportRoot
            if ($a.epoch -eq $Epoch -and $a.runId -eq $RunId) {
                $a.result = $result
                $a.reportPaths = $paths
                $a.partial = [bool](@($result.packs | Where-Object { $_.coverage.inventory -eq 'partial' }).Count -or
                    @($result.controls | Where-Object status -eq 'notAssessed').Count -or $result.collectionIssues.Count -or
                    @($result.sources | Where-Object { -not $_.complete }).Count)
                $a.percent = 100; $a.phase = (Get-IdsText -Key 'text.completed')
            }
        } catch {
            if ($a.epoch -eq $Epoch -and $a.runId -eq $RunId) {
                # Transport/provider exceptions may contain credentials or payloads.
                $a.error = (Get-IdsText -Key 'text.assessment_failed_during_arg0_no_successful_report_pair_is_available' -Arguments @{ arg0 = ($a.phase) })
                $a.result = $null; $a.reportPaths = $null; $a.phase = (Get-IdsText -Key 'text.failed')
            }
        } finally {
            if ($a.epoch -eq $Epoch -and $a.runId -eq $RunId) { $a.done = $true; $a.running = $false }
        }
    }
    $runspace = $null
    $ps = $null
    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($worker).AddArgument($Root).AddArgument($State).AddArgument($resolved).AddArgument($auth).AddArgument($epoch).AddArgument($runId).AddArgument($loadedPolicies)
        $handle = $ps.BeginInvoke()
        $assessment.job = @{ ps = $ps; handle = $handle; runspace = $runspace }
        return $true
    } catch {
        if ($ps) { $ps.Dispose() }
        if ($runspace) { $runspace.Dispose() }
        $assessment.running = $false; $assessment.done = $true; $assessment.phase = (Get-IdsText -Key 'text.failed')
        $assessment.error = (Get-IdsText -Key 'text.unable_to_start_assessment_worker')
        throw [InvalidOperationException]::new($assessment.error)
    }
}

function Clear-IdsAssessmentJob {
    param([hashtable]$State)
    $job = $State.Assessment.job
    if (-not $job -or -not $job.handle.IsCompleted) { return }
    try { [void]$job.ps.EndInvoke($job.handle) } catch {
        $State.Assessment.error = (Get-IdsText -Key 'text.assessment_worker_terminated_unexpectedly' -Locale $State.Assessment.locale)
        $State.Assessment.result = $null; $State.Assessment.reportPaths = $null
    } finally {
        $job.ps.Dispose(); $job.runspace.Dispose()
        $State.Assessment.job = $null
        if ($State.Assessment.running) {
            $State.Assessment.error = (Get-IdsText -Key 'text.assessment_worker_terminated_unexpectedly' -Locale $State.Assessment.locale)
            $State.Assessment.running = $false; $State.Assessment.done = $true
        }
    }
}

function Stop-IdsAssessmentJob {
    param([hashtable]$State)
    $wasRunning = $State.Assessment.running
    $job = $State.Assessment.job
    if ($job) {
        try { $job.ps.Stop() } catch { }
        try { $job.ps.Dispose() } finally { $job.runspace.Dispose(); $State.Assessment.job = $null }
    }
    if ($State.Assessment) {
        $State.Assessment.running = $false
        if ($wasRunning) {
            $State.Assessment.done = $true; $State.Assessment.error = (Get-IdsText -Key 'text.assessment_cancelled' -Locale $State.Assessment.locale)
            $State.Assessment.phase = (Get-IdsText -Key 'text.cancelled' -Locale $State.Assessment.locale); $State.Assessment.result = $null; $State.Assessment.reportPaths = $null
        }
    }
}

function Reset-IdsAssessment {
    param([hashtable]$State)
    if (Test-IdsWorkActive $State) { throw (Get-IdsText -Key 'text.an_export_or_assessment_is_still_running') }
    Initialize-IdsAssessment $State
    Clear-IdsAssessmentJob $State
    $a = $State.Assessment
    $a.epoch = [long]$a.epoch + 1
    $a.resultEpoch = $null; $a.runId = $null; $a.result = $null
    $a.reportPaths = $null; $a.error = $null; $a.percent = 0; $a.phase = ''
    $a.running = $false; $a.done = $false; $a.partial = $false
    $State.Pending = $null
}
