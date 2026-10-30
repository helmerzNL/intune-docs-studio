. (Join-Path $PSScriptRoot 'Localization.ps1')

function Initialize-IdsPolicyInventory {
    param([hashtable]$State)
    if (-not $State.Policies) {
        $State.Policies = [hashtable]::Synchronized(@{
            status = 'idle'; running = $false; phase = ''; percent = 0; error = $null
            epoch = $null; identity = $null; snapshot = $null; job = $null
        })
    }
}

function Get-IdsPolicyIdentity {
    param([hashtable]$State)
    if (-not $State.Auth) { return '' }
    return ConvertTo-Json -Compress -InputObject @(
        $State.Auth.tenant_id, $State.Auth.account, $State.Auth.client_id, $State.Auth.method
    )
}

function Test-IdsPolicyOwner {
    param([hashtable]$State, [hashtable]$Inventory)
    if (-not [object]::ReferenceEquals($State.Policies, $Inventory) -or
        $Inventory.epoch -ne $State.Assessment.epoch) { return $false }
    if ($Inventory.sourceKind -eq 'offline') { return [bool]$Inventory.snapshot }
    return [bool]($State.Auth -and $Inventory.identity -ceq (Get-IdsPolicyIdentity $State))
}

function Get-IdsLoadedPolicies {
    param([hashtable]$State)
    if (-not $State.Policies -or -not (Test-IdsPolicyOwner $State $State.Policies) -or
        $State.Policies.status -notin @('ready', 'partial') -or -not $State.Policies.snapshot) {
        throw (Get-IdsText -Key 'text.load_policies_or_import_a_policy_set_before_documenting_or_assessing')
    }
    return $State.Policies.snapshot
}

function Get-IdsPolicySummary {
    param([hashtable]$State)
    $inventory = $State.Policies
    $owned = $inventory -and (Test-IdsPolicyOwner $State $inventory)
    $snapshot = if ($owned) { $inventory.snapshot } else { $null }
    $families = [ordered]@{
        settingsCatalog = (Get-IdsText -Key 'text.settings_catalog'); deviceConfiguration = (Get-IdsText -Key 'text.configuration_profiles')
        compliance = (Get-IdsText -Key 'text.compliance_policies'); admx = (Get-IdsText -Key 'text.administrative_templates'); intent = (Get-IdsText -Key 'text.endpoint_security')
    }
    return @{
        status = $(if ($owned) { $inventory.status } else { 'idle' })
        percent = $(if ($owned) { $inventory.percent } else { 0 })
        phase = $(if ($owned) { $inventory.phase } else { '' })
        error = $(if ($owned) { $inventory.error } else { $null })
        capturedAt = $snapshot.capturedAt
        locale = $inventory.locale
        source = $snapshot.source
        tenant = $snapshot.tenant
        consentRequired = [bool]($State.Auth -and
            ($State.PolicyConsent.identity -cne (Get-IdsPolicyIdentity $State) -or
                $State.PolicyConsent.decision -eq 'pending'))
        count = @($snapshot.collection.policies | Where-Object { $null -ne $_ }).Count
        families = @(if ($snapshot) { foreach ($family in $families.Keys) {
            @{
                key = $family
                label = $families[$family]
                count = @($snapshot.collection.policies | Where-Object family -EQ $family).Count
                complete = @($snapshot.collection.issues + $snapshot.collection.documentationIssues |
                    Where-Object family -EQ $family).Count -eq 0 -and
                    @($snapshot.collection.sources | Where-Object { $_.family -eq $family -and -not $_.complete }).Count -eq 0 -and
                    @($snapshot.collection.policies | Where-Object { $_.family -eq $family -and -not $_.settingsComplete }).Count -eq 0
            }
        } })
        issues = @(if ($snapshot) {
            foreach ($issue in @($snapshot.collection.issues) + @($snapshot.collection.documentationIssues)) {
                @{ family = $issue.family; stage = $issue.stage; reason = $issue.reason; statusCode = $issue.statusCode }
            }
        })
    }
}

function Get-IdsPolicyTenant {
    param([hashtable]$Auth)
    try {
        $organization = Invoke-IdsGraph -Path '/organization?$select=id,displayName' -Version 'v1.0'
        $tenants = @(Get-IdsAssessmentMember $organization 'value')
    } catch {
        if ($_.Exception.StatusCode -notin @(403, 404) -or -not $Auth.tenant_id) { throw }
        $tenants = @(@{ id = $Auth.tenant_id; displayName = '' })
    }
    if ($tenants.Count -ne 1 -or -not $tenants[0].id) { throw (Get-IdsText -Key 'text.cannot_establish_authenticated_tenant') }
    if ($Auth.tenant_id -and $Auth.tenant_id -ne $tenants[0].id) { throw (Get-IdsText -Key 'text.authenticated_tenant_does_not_match_the_session') }
    return @{ id = [string]$tenants[0].id; name = [string]$tenants[0].displayName }
}

function Select-IdsPolicyCollection {
    param($Snapshot, [object[]]$Packs, [hashtable]$Context)
    $families = @($Packs.controls.mappings.family | Sort-Object -Unique)
    $collection = $Snapshot.collection
    return [pscustomobject]@{
        policies = @($collection.policies | Where-Object family -CIn $families)
        issues = @($collection.issues | Where-Object family -CIn $families)
        sources = @($collection.sources | Where-Object {
            $source = $_
            $source.platform -cin $Context.platforms -and @($Packs | Where-Object {
                $_.platform -ceq $source.platform -and $_.controls.mappings.family -ccontains $source.family
            }).Count -gt 0
        })
    }
}

function Start-IdsPolicyLoad {
    param([hashtable]$State, [string]$Root)
    if (Test-IdsWorkActive $State) { return $false }
    if (-not $State.Auth) { throw (Get-IdsText -Key 'text.not_signed_in') }
    Initialize-IdsPolicyInventory $State
    Clear-IdsPolicyLoadJob $State
    $inventory = $State.Policies
    $inventory.epoch = $State.Assessment.epoch
    $inventory.identity = Get-IdsPolicyIdentity $State
    $inventory.sourceKind = 'live'
    $State.PolicyConsent = @{ identity = $inventory.identity; decision = 'accepted' }
    $inventory.snapshot = $null
    $inventory.error = $null
    $inventory.percent = 0
    $inventory.phase = (Get-IdsText -Key 'text.verifying_tenant')
    $inventory.locale = Get-IdsLocale
    $inventory.status = 'loading'
    $inventory.running = $true
    $auth = @{}
    foreach ($key in $State.Auth.Keys) { $auth[$key] = $State.Auth[$key] }
    $worker = {
        param($Root, $State, $Inventory, $Auth, $Locale)
        $ErrorActionPreference = 'Stop'
        $requiresSignIn = $false
        try {
            . (Join-Path $Root 'lib\Localization.ps1')
            Set-IdsLocale -Locale $Locale
            foreach ($module in 'Auth', 'Graph', 'BaselinePacks', 'AssessmentCollection', 'PolicyInventory') {
                . (Join-Path $Root "lib\$module.ps1")
            }
            if ($Auth.transport -eq 'mggraph') { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop }
            $holder = @{ Auth = $Auth }
            Initialize-IdsGraph $holder
            $tenant = Get-IdsPolicyTenant $Auth
            $Inventory.phase = (Get-IdsText -Key 'text.loading_policies')
            $progress = {
                param($Phase, $Percent)
                $Inventory.phase = (Get-IdsText -Key 'text.loading_arg0' -Arguments @{ arg0 = ($Phase) })
                $Inventory.percent = $Percent
            }.GetNewClosure()
            $collection = Get-IdsAssessmentCollection -AllPolicies -IncludeDocumentation -ProgressCallback $progress
            $issues = @($collection.issues) + @($collection.documentationIssues)
            if (@($issues | Where-Object { $_.statusCode -eq 401 -or $_.authenticationFailure }).Count) {
                $requiresSignIn = $true
                throw (Get-IdsText -Key 'text.policy_authentication_failed')
            }
            $failedFamilies = @($collection.issues | Where-Object stage -EQ 'inventory' | Select-Object -ExpandProperty family -Unique)
            if ($collection.policies.Count -eq 0 -and $failedFamilies.Count -eq 5) { throw (Get-IdsText -Key 'text.no_policy_source_could_be_loaded') }
            if (Test-IdsPolicyOwner $State $Inventory) {
                $Inventory.snapshot = @{
                    tenant = $tenant; capturedAt = [datetime]::UtcNow.ToString('o'); collection = $collection
                    source = @{ kind = 'live'; name = $tenant.name; importedAt = $null }
                }
                # Only this session can receive tokens refreshed by its own worker.
                $State.Auth = $holder.Auth
                $Inventory.percent = 100
                $Inventory.status = if ($issues.Count) { 'partial' } else { 'ready' }
                $Inventory.phase = if ($issues.Count) { (Get-IdsText -Key 'text.loaded_with_limitations') } else { (Get-IdsText -Key 'text.policies_loaded') }
            }
        } catch {
            if (Test-IdsPolicyOwner $State $Inventory) {
                if ($requiresSignIn -or (Test-IdsGraphAuthenticationFailure $_.Exception)) {
                    $Inventory.error = (Get-IdsText -Key 'text.policy_authentication_failed')
                } else {
                    $Inventory.error = (Get-IdsText -Key 'text.could_not_load_policies_during_arg0_retry_or_sign_out_and_check_your_intune_read_permissions' -Arguments @{ arg0 = ($Inventory.phase) })
                }
                $Inventory.snapshot = $null
                $Inventory.status = 'failed'
                $Inventory.phase = (Get-IdsText -Key 'text.loading_failed')
            }
        } finally { $Inventory.running = $false }
    }
    $runspace = $null; $ps = $null
    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($worker).AddArgument($Root).AddArgument($State).AddArgument($inventory).AddArgument($auth).AddArgument($inventory.locale)
        $inventory.job = @{ ps = $ps; handle = $ps.BeginInvoke(); runspace = $runspace }
        return $true
    } catch {
        if ($ps) { $ps.Dispose() }
        if ($runspace) { $runspace.Dispose() }
        $inventory.running = $false; $inventory.status = 'failed'
        $inventory.error = (Get-IdsText -Key 'text.unable_to_start_policy_loading_retry_or_restart_intune_docs_studio')
        return $false
    }
}

function Clear-IdsPolicyLoadJob {
    param([hashtable]$State)
    $inventory = $State.Policies
    $job = $inventory.job
    if (-not $job -or -not $job.handle.IsCompleted) { return }
    try { [void]$job.ps.EndInvoke($job.handle) } catch {
        $inventory.status = 'failed'; $inventory.snapshot = $null
        $inventory.error = (Get-IdsText -Key 'text.policy_loading_ended_unexpectedly_retry_or_restart_intune_docs_studio' -Locale $inventory.locale)
    } finally {
        $job.ps.Dispose(); $job.runspace.Dispose(); $inventory.job = $null
        if ($inventory.running -or $inventory.status -eq 'loading') {
            $inventory.status = 'failed'; $inventory.snapshot = $null
            $inventory.error = (Get-IdsText -Key 'text.policy_loading_ended_unexpectedly_retry_or_restart_intune_docs_studio' -Locale $inventory.locale)
        }
        $inventory.running = $false
    }
}

function Stop-IdsPolicyLoad {
    param([hashtable]$State)
    $job = $State.Policies.job
    # Detach ownership before stopping so a late worker cannot publish.
    $State.Policies = $null
    Initialize-IdsPolicyInventory $State
    if ($job) {
        try { $job.ps.Stop() } finally { $job.ps.Dispose(); $job.runspace.Dispose() }
    }
}

function Sync-IdsPolicyLoad {
    param([hashtable]$State, [string]$Root)
    Clear-IdsPolicyLoadJob $State
    if ($State.Policies.status -ne 'idle' -and -not (Test-IdsPolicyOwner $State $State.Policies)) {
        Stop-IdsPolicyLoad $State
    }
}
