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
        throw 'Load policies or import a policy set before documenting or assessing.'
    }
    return $State.Policies.snapshot
}

function Get-IdsPolicySummary {
    param([hashtable]$State)
    $inventory = $State.Policies
    $owned = $inventory -and (Test-IdsPolicyOwner $State $inventory)
    $snapshot = if ($owned) { $inventory.snapshot } else { $null }
    $families = [ordered]@{
        settingsCatalog = 'Settings catalog'; deviceConfiguration = 'Configuration profiles'
        compliance = 'Compliance policies'; admx = 'Administrative templates'; intent = 'Endpoint security'
    }
    return @{
        status = $(if ($owned) { $inventory.status } else { 'idle' })
        percent = $(if ($owned) { $inventory.percent } else { 0 })
        phase = $(if ($owned) { $inventory.phase } else { '' })
        error = $(if ($owned) { $inventory.error } else { $null })
        capturedAt = $snapshot.capturedAt
        source = $snapshot.source
        tenant = $snapshot.tenant
        consentRequired = [bool]($State.Auth -and
            ($State.PolicyConsent.identity -cne (Get-IdsPolicyIdentity $State) -or
                $State.PolicyConsent.decision -eq 'pending'))
        count = @($snapshot.collection.policies | Where-Object { $null -ne $_ }).Count
        families = @(if ($snapshot) { foreach ($family in $families.Keys) {
            @{
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
    if ($tenants.Count -ne 1 -or -not $tenants[0].id) { throw 'Cannot establish authenticated tenant.' }
    if ($Auth.tenant_id -and $Auth.tenant_id -ne $tenants[0].id) { throw 'Authenticated tenant does not match the session.' }
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
    if (-not $State.Auth) { throw 'Not signed in.' }
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
    $inventory.phase = 'Verifying tenant'
    $inventory.status = 'loading'
    $inventory.running = $true
    $auth = @{}
    foreach ($key in $State.Auth.Keys) { $auth[$key] = $State.Auth[$key] }
    $worker = {
        param($Root, $State, $Inventory, $Auth)
        $ErrorActionPreference = 'Stop'
        try {
            foreach ($module in 'Auth', 'Graph', 'BaselinePacks', 'AssessmentCollection', 'PolicyInventory') {
                . (Join-Path $Root "lib\$module.ps1")
            }
            if ($Auth.transport -eq 'mggraph') { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop }
            $holder = @{ Auth = $Auth }
            Initialize-IdsGraph $holder
            $tenant = Get-IdsPolicyTenant $Auth
            $Inventory.phase = 'Loading policies'
            $progress = {
                param($Phase, $Percent)
                $Inventory.phase = "Loading $Phase"
                $Inventory.percent = $Percent
            }.GetNewClosure()
            $collection = Get-IdsAssessmentCollection -AllPolicies -IncludeDocumentation -ProgressCallback $progress
            $issues = @($collection.issues) + @($collection.documentationIssues)
            if (@($issues | Where-Object { $_.statusCode -eq 401 -or $_.authenticationFailure }).Count) {
                throw 'Policy authentication failed.'
            }
            $failedFamilies = @($collection.issues | Where-Object stage -EQ 'inventory' | Select-Object -ExpandProperty family -Unique)
            if ($collection.policies.Count -eq 0 -and $failedFamilies.Count -eq 5) { throw 'No policy source could be loaded.' }
            if (Test-IdsPolicyOwner $State $Inventory) {
                $Inventory.snapshot = @{
                    tenant = $tenant; capturedAt = [datetime]::UtcNow.ToString('o'); collection = $collection
                    source = @{ kind = 'live'; name = $tenant.name; importedAt = $null }
                }
                # Only this session can receive tokens refreshed by its own worker.
                $State.Auth = $holder.Auth
                $Inventory.percent = 100
                $Inventory.status = if ($issues.Count) { 'partial' } else { 'ready' }
                $Inventory.phase = if ($issues.Count) { 'Loaded with limitations' } else { 'Policies loaded' }
            }
        } catch {
            if (Test-IdsPolicyOwner $State $Inventory) {
                $Inventory.error = "Could not load policies during $($Inventory.phase). Retry, or sign out and check your Intune read permissions."
                $Inventory.snapshot = $null
                $Inventory.status = 'failed'
                $Inventory.phase = 'Loading failed'
            }
        } finally { $Inventory.running = $false }
    }
    $runspace = $null; $ps = $null
    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($worker).AddArgument($Root).AddArgument($State).AddArgument($inventory).AddArgument($auth)
        $inventory.job = @{ ps = $ps; handle = $ps.BeginInvoke(); runspace = $runspace }
        return $true
    } catch {
        if ($ps) { $ps.Dispose() }
        if ($runspace) { $runspace.Dispose() }
        $inventory.running = $false; $inventory.status = 'failed'
        $inventory.error = 'Unable to start policy loading. Retry or restart Intune Docs Studio.'
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
        $inventory.error = 'Policy loading ended unexpectedly. Retry or restart Intune Docs Studio.'
    } finally {
        $job.ps.Dispose(); $job.runspace.Dispose(); $inventory.job = $null
        if ($inventory.running -or $inventory.status -eq 'loading') {
            $inventory.status = 'failed'; $inventory.snapshot = $null
            $inventory.error = 'Policy loading ended unexpectedly. Retry or restart Intune Docs Studio.'
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
