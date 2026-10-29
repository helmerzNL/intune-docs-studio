. (Join-Path $PSScriptRoot 'Localization.ps1')

function Assert-IdsLocalJsonRequest {
    param($Request, [hashtable]$State)
    $expected = "http://localhost:$($State.Config.Port)"
    if ($Request.Headers['Host'] -cne ([uri]$expected).Authority -or $Request.Headers['Origin'] -cne $expected) {
        throw [UnauthorizedAccessException]::new((Get-IdsText -Key 'text.same_origin_request_required'))
    }
    if ($Request.ContentType -notmatch '^(?i:application/json)(?:\s*;\s*charset\s*=\s*(?i:utf-8))?\s*$') {
        throw [NotSupportedException]::new((Get-IdsText -Key 'text.content_type_must_be_application_json_with_utf_8_encoding'))
    }
}

function ConvertFrom-IdsPolicyArchiveBase64 {
    param($Text)
    if ($Text -isnot [string] -or $Text.Length -gt 44739244 -or $Text.Length % 4 -or $Text -cnotmatch '\A[A-Za-z0-9+/]*={0,2}\z') {
        throw (Get-IdsText -Key 'text.policy_archive_must_be_strict_base64_of_a_zip_no_larger_than_32_mib')
    }
    return ,([Convert]::FromBase64String($Text))
}

function Set-IdsActivePolicySnapshot {
    param([hashtable]$State, $Snapshot, [string]$Locale = (Get-IdsLocale))
    Reset-IdsAssessment $State
    Stop-IdsPolicyLoad $State
    $State.Policies.snapshot = $Snapshot
    $State.Policies.sourceKind = $Snapshot.source.kind
    $State.Policies.epoch = $State.Assessment.epoch
    $State.Policies.identity = Get-IdsPolicyIdentity $State
    $State.Policies.status = if (@($Snapshot.collection.issues).Count -or @($Snapshot.collection.documentationIssues).Count) { 'partial' } else { 'ready' }
    $State.Policies.percent = 100
    $State.Policies.phase = (Get-IdsText -Key 'text.policy_set_imported' -Locale $Locale)
    $State.Policies.locale = $Locale
    $State.Export.log.Clear()
    $State.Export.summary = $null; $State.Export.error = $null; $State.Export.done = $false
    $State.Config.OutputPath = $State.Config.DefaultOutputPath
}

function Start-IdsPolicyTransfer {
    param([hashtable]$State, [string]$Root, [hashtable]$Options)
    if (Test-IdsWorkActive $State) { return $false }
    $Options = @{} + $Options
    $Options.Locale = Get-IdsLocale
    $snapshot = if ($Options.operation -eq 'export') { Get-IdsLoadedPolicies $State } else { $null }
    $transfer = [hashtable]::Synchronized(@{
        running = $true; status = 'running'; operation = $Options.operation
        locale = $Options.Locale
        phase = $(if ($snapshot) { (Get-IdsText -Key 'text.writing_policy_json_files') } else { (Get-IdsText -Key 'text.reading_and_validating_policy_files') })
        error = $null; result = $null; candidate = $null; job = $null; epoch = $State.Assessment.epoch
    })
    $State.PolicyTransfer = $transfer
    $worker = {
        param($Root, $Transfer, $Options, $Snapshot)
        $ErrorActionPreference = 'Stop'
        try {
            . (Join-Path $Root 'lib\Localization.ps1')
            Set-IdsLocale -Locale $Options.Locale
            foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'BaselineArchive', 'AssessmentReports', 'Assessment', 'PolicySnapshots') {
                . (Join-Path $Root "lib\$module.ps1")
            }
            if ($Options.operation -eq 'import') {
                $Transfer.candidate = Import-IdsPolicySnapshot -Path $Options.path -Archive $Options.archive
            } else {
                $Transfer.result = Export-IdsPolicySnapshot $Snapshot $Options.path $Root
            }
            $Transfer.status = 'validated'; $Transfer.phase = (Get-IdsText -Key 'text.finishing')
        } catch {
            $Transfer.status = 'failed'; $Transfer.error = $_.Exception.Message
            $Transfer.phase = (Get-IdsText -Key 'text.policy_transfer_failed_the_active_source_was_not_replaced')
        }
    }
    $rs = $null; $ps = $null
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($worker).AddArgument($Root).AddArgument($transfer).AddArgument($Options).AddArgument($snapshot)
        $transfer.job = @{ ps = $ps; runspace = $rs; handle = $ps.BeginInvoke() }
        return $true
    } catch {
        if ($ps) { $ps.Dispose() }; if ($rs) { $rs.Dispose() }
        $transfer.running = $false; $transfer.status = 'failed'; $transfer.error = (Get-IdsText -Key 'text.could_not_start_the_policy_transfer_worker')
        return $false
    }
}

function Sync-IdsPolicyTransfer {
    param([hashtable]$State)
    $transfer = $State.PolicyTransfer; $job = $transfer.job
    if (-not $job -or -not $job.handle.IsCompleted) { return }
    try { [void]$job.ps.EndInvoke($job.handle) } catch {
        $transfer.status = 'failed'; $transfer.error = (Get-IdsText -Key 'text.policy_transfer_worker_ended_unexpectedly' -Locale $transfer.locale)
    } finally {
        $job.ps.Dispose(); $job.runspace.Dispose(); $transfer.job = $null; $transfer.running = $false
    }
    if ($transfer.status -eq 'validated') {
        if ($transfer.epoch -ne $State.Assessment.epoch) {
            $transfer.status = 'failed'; $transfer.error = (Get-IdsText -Key 'text.source_session_changed_during_import_retry' -Locale $transfer.locale)
        } else {
            if ($transfer.operation -eq 'import') {
                Set-IdsActivePolicySnapshot $State $transfer.candidate -Locale $transfer.locale
                $transfer.result = @{ policies = @($transfer.candidate.collection.policies).Count }
            }
            $transfer.status = 'completed'; $transfer.phase = (Get-IdsText -Key 'text.completed' -Locale $transfer.locale)
        }
    }
    $transfer.candidate = $null
}

function Stop-IdsPolicyTransfer {
    param([hashtable]$State)
    $job = $State.PolicyTransfer.job
    if ($job) { try { $job.ps.Stop() } finally { $job.ps.Dispose(); $job.runspace.Dispose() } }
    $State.PolicyTransfer = $null
}

function Invoke-IdsPolicyRoute {
    param([string]$Method, [string]$Path, $Request, [hashtable]$State, [string]$Root)
    $response = [pscustomobject]@{ handled = $true; status = 200; body = $null }
    if ("$Method $Path" -cnotin @('POST /api/policies/import', 'POST /api/policies/export',
        'POST /api/policies/decline', 'GET /api/policies/transfer',
        'POST /api/folders/picker', 'GET /api/folders/picker')) {
        $response.handled = $false; return $response
    }
    try {
        Sync-IdsPolicyTransfer $State
        Sync-IdsFolderPicker $State
        if ($Method -eq 'POST') { Assert-IdsLocalJsonRequest $Request $State }
        if ($Method -eq 'POST' -and (Test-IdsWorkActive $State)) {
            $response.status = 409; $response.body = @{ error = (Get-IdsText -Key 'text.another_import_policy_load_export_assessment_or_sign_in_is_running') }; return $response
        }
        switch ("$Method $Path") {
            'POST /api/policies/decline' {
                if (-not $State.Auth) { $response.status = 401; $response.body = @{ error = (Get-IdsText -Key 'text.not_signed_in') }; break }
                $State.PolicyConsent = @{ identity = Get-IdsPolicyIdentity $State; decision = 'declined' }
                if ($State.Policies.status -eq 'failed') { Stop-IdsPolicyLoad $State }
                $response.body = @{ ok = $true }
            }
            'POST /api/folders/picker' {
                $body = Read-IdsAssessmentRequestJson $Request 4KB
                if (Start-IdsFolderPicker $State $Root ([string]$body.initialPath)) {
                    $response.status = 202; $response.body = @{ started = $true }
                } else { $response.status = 409; $response.body = @{ error = (Get-IdsText -Key 'text.a_folder_dialog_is_already_open_or_could_not_start') } }
            }
            'GET /api/folders/picker' {
                $picker = $State.FolderPicker
                $response.body = @{ status = $(if ($picker) { $picker.status } else { 'idle' }); path = $picker.path; error = $picker.error }
            }
            'POST /api/policies/import' {
                $body = Read-IdsAssessmentRequestJson $Request 64MB
                $fields = @{}
                foreach ($property in $body.PSObject.Properties) { $fields[$property.Name] = $property.Value }
                Assert-IdsAssessmentFields $fields @('path', 'archive', 'replace') @()
                if ($fields.ContainsKey('replace') -and $body.replace -isnot [bool]) { throw (Get-IdsText -Key 'text.replacement_confirmation_must_be_a_boolean') }
                if ($State.Policies.snapshot -and $body.replace -ne $true) {
                    $response.status = 409; $response.body = @{ error = (Get-IdsText -Key 'text.confirm_replacement_of_the_active_policy_source') }; break
                }
                if (($null -ne $body.path) -eq ($null -ne $body.archive)) { throw (Get-IdsText -Key 'text.provide_exactly_one_folder_zip_path_or_zip_upload') }
                if ($null -ne $body.path -and ($body.path -isnot [string] -or [string]::IsNullOrWhiteSpace($body.path))) { throw (Get-IdsText -Key 'text.choose_an_absolute_host_policy_folder_or_zip_path') }
                $options = @{ operation = 'import'; path = $body.path; archive = $null }
                if ($null -ne $body.archive) { $options.archive = ConvertFrom-IdsPolicyArchiveBase64 $body.archive }
                if (-not (Start-IdsPolicyTransfer $State $Root $options)) { throw (Get-IdsText -Key 'text.policy_import_could_not_start') }
                $response.status = 202; $response.body = @{ started = $true }
            }
            'POST /api/policies/export' {
                $body = Read-IdsAssessmentRequestJson $Request 4KB
                if ($body.path -isnot [string]) { throw (Get-IdsText -Key 'text.choose_an_export_destination_folder') }
                if (-not (Start-IdsPolicyTransfer $State $Root @{ operation = 'export'; path = $body.path })) { throw (Get-IdsText -Key 'text.policy_export_could_not_start') }
                $response.status = 202; $response.body = @{ started = $true }
            }
            'GET /api/policies/transfer' {
                $t = $State.PolicyTransfer
                $response.body = @{ status = $(if ($t) { $t.status } else { 'idle' }); running = [bool]$t.running; phase = $t.phase; error = $t.error; result = $t.result }
            }
        }
    } catch [UnauthorizedAccessException] { $response.status = 403; $response.body = @{ error = $_.Exception.Message }
    } catch [NotSupportedException] { $response.status = 415; $response.body = @{ error = $_.Exception.Message }
    } catch { $response.status = 400; $response.body = @{ error = $_.Exception.Message } }
    return $response
}
