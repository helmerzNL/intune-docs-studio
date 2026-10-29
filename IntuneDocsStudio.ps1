#requires -Version 7.0
<#PSScriptInfo
.SYNOPSIS  Intune Docs Studio — document Intune to Markdown without an Entra ID app registration.
#>
<#
    .SYNOPSIS
        Local dashboard and exporter that turns an Intune tenant into a structured Markdown
        repository, ready to publish to a Git or Azure DevOps repo.

    .DESCRIPTION
        Signs in interactively as an administrator using a Microsoft first-party public client
        and read-only delegated Graph permissions. No app registration, no client secret.

    .EXAMPLE
        .\IntuneDocsStudio.ps1
        Opens the dashboard at http://localhost:7654

    .EXAMPLE
        .\IntuneDocsStudio.ps1 -Export -Method devicecode -OutputPath C:\repos\intune-docs -GitCommit
        Headless export suitable for a scheduled task or pipeline agent.
#>
[CmdletBinding()]
param(
    [int]$Port = 7654,
    [string]$OutputPath,
    [string]$Tenant = 'organizations',
    [ValidateSet('graphcli', 'azurecli', 'intuneps')][string]$Client = 'graphcli',
    [switch]$NoBrowser,

    # Headless mode
    [switch]$Export,
    [ValidateSet('interactive', 'devicecode', 'azurecli', 'mggraph', 'browser')][string]$Method = 'interactive',
    [string[]]$Sections,
    [switch]$GitCommit,
    [switch]$GitPush,
    [string]$GitMessage,
    [string]$GitRemoteUrl,
    [string]$GitBranch,
    [switch]$NoRawJson,
    [switch]$NoScriptContent,
    [switch]$NoFrontMatter,
    [switch]$NoAdoOrder
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = $PSScriptRoot
. (Join-Path $Root 'lib\Version.ps1')
$Build = Get-IdsBuildInfo -Root $Root
. (Join-Path $Root 'lib\Auth.ps1')
. (Join-Path $Root 'lib\Graph.ps1')
. (Join-Path $Root 'lib\BrowserSession.ps1')
. (Join-Path $Root 'lib\Render.ps1')
. (Join-Path $Root 'lib\Export.ps1')
. (Join-Path $Root 'lib\Http.ps1')
foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'BaselineArchive', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi', 'PolicyInventory', 'PolicySnapshots', 'LocalFolders', 'PolicyApi', 'ReferencePacks') {
    . (Join-Path $Root "lib\$module.ps1")
}

if (-not $OutputPath) { $OutputPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'intune-docs' }

# --- Shared state -----------------------------------------------------------------------

$State = [hashtable]::Synchronized(@{
        Auth    = $null
        Pending = $null
        Job     = $null
        Browser = [hashtable]::Synchronized(@{ running = $false; status = ''; error = $null })
        Export  = [hashtable]::Synchronized(@{
                running = $false
                done    = $false
                error   = $null
                percent = 0
                phase   = ''
                log     = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
                summary = $null
            })
        Config  = @{ Port = $Port; OutputPath = $OutputPath; DefaultOutputPath = $OutputPath; Root = $Root; Tenant = $Tenant; DefaultTenant = $Tenant
            ImportedPackRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'IntuneDocsStudio\AssessmentPacks') }
    })

Initialize-IdsAssessment $State
if (-not $Export) { Initialize-IdsPolicyInventory $State }
Initialize-IdsGraph -StateHolder $State

function Get-IdsDefaultOptions {
    return @{
        OutputPath           = $State.Config.OutputPath
        Sections             = @(if ($State.Policies.snapshot.source.kind -eq 'offline') {
            'settingsCatalog', 'deviceConfigs', 'admx', 'compliance', 'endpointSecurity'
        } else { (Get-IdsSectionCatalog).Keys })
        IncludeRaw           = $true
        IncludeRawFiles      = $true
        IncludeScriptContent = $true
        FrontMatter          = $true
        AdoWikiOrder         = $true
        GitCommit            = $false
        GitPush              = $false
        GitMessage           = ''
        GitRemoteUrl         = ''
        GitBranch            = ''
        AllowTenantOverwrite = $false
    }
}

function Get-IdsFolderSuggestion {
    <#  Proposes a sibling folder named after the tenant, so documenting a second tenant does
        not land on top of the first one's repository. #>
    param([string]$CurrentPath, [string]$TenantName, [string]$TenantId)
    $label = $TenantName
    if (-not $label) { $label = $TenantId }
    if (-not $label) { return $CurrentPath }
    $slug = ($label -replace '[^\p{L}\p{Nd}]+', '-').Trim('-').ToLowerInvariant()
    if (-not $slug) { $slug = 'tenant' }
    $parent = [IO.Path]::GetDirectoryName($CurrentPath)
    if (-not $parent) { $parent = [Environment]::GetFolderPath('MyDocuments') }
    return (Join-Path $parent "intune-docs-$slug")
}

function Start-IdsExportJob {
    <#  Runs the export in its own runspace so the dashboard stays responsive. #>
    param([hashtable]$Options)
    if ((Test-IdsWorkActive $State) -or $State.Browser.running) { return $false }
    Clear-IdsFinishedJob
    $policySnapshot = Get-IdsLoadedPolicies $State

    $State.Export.log.Clear()
    $State.Export.summary = $null
    $State.Export.error = $null
    $State.Export.percent = 0
    $State.Export.phase = 'Starting'
    $State.Export.running = $true
    $State.Export.done = $false

    $script = {
        param($Root, $State, $Options, $PolicySnapshot)
        try {
            . (Join-Path $Root 'lib\Auth.ps1')
            . (Join-Path $Root 'lib\Graph.ps1')
            . (Join-Path $Root 'lib\Render.ps1')
            . (Join-Path $Root 'lib\Export.ps1')
            if ($PolicySnapshot.source.kind -ne 'offline') {
                if ($State.Auth -and $State.Auth.transport -eq 'mggraph') {
                    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
                }
                Initialize-IdsGraph -StateHolder $State
                Reset-IdsGraphStats
            }
            Start-IdsExport -State $State -Options $Options -PolicySnapshot $PolicySnapshot
        } catch {
            $State.Export.error = $_.Exception.Message
            $State.Export.running = $false
            $State.Export.done = $true
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($script).AddArgument($Root).AddArgument($State).AddArgument($Options).AddArgument($policySnapshot)
    $handle = $ps.BeginInvoke()
    $State.Job = @{ ps = $ps; handle = $handle; runspace = $runspace }
    return $true
}

function Start-IdsBrowserSignIn {
    <#  Runs the browser capture in its own runspace: it blocks for as long as the sign-in
        takes, and the dashboard must keep serving requests meanwhile. #>
    param([string]$TenantId, [bool]$ForcePicker = $false)
    if ((Test-IdsWorkActive $State) -or $State.Browser.running) { return $false }
    Clear-IdsFinishedJob
    Reset-IdsSessionState
    $epoch = $State.Assessment.epoch
    $State.Browser.running = $true
    $State.Browser.error = $null
    $State.Browser.status = 'Starting browser…'

    $script = {
        param($Root, $State, $TenantId, $ForcePicker, $Epoch)
        try {
            . (Join-Path $Root 'lib\Auth.ps1')
            . (Join-Path $Root 'lib\BrowserSession.ps1')
            $cb = { param($m) $State.Browser.status = $m }.GetNewClosure()
            $auth = Get-IdsTokenFromBrowser -Tenant $TenantId -StatusCallback $cb -ForceAccountPicker:$ForcePicker
            if ($State.Assessment.epoch -eq $Epoch) {
                $State.Auth = $auth
                $State.Browser.status = 'Connected'
            }
        } catch {
            $State.Browser.error = $_.Exception.Message
        } finally {
            $State.Browser.running = $false
        }
    }
    $rs = $null; $ps = $null
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script).AddArgument($Root).AddArgument($State).AddArgument($TenantId).AddArgument($ForcePicker).AddArgument($epoch)
        $handle = $ps.BeginInvoke()
        $State.Browser.job = @{ ps = $ps; handle = $handle; runspace = $rs }
    } catch {
        if ($ps) { $ps.Dispose() }
        if ($rs) { $rs.Dispose() }
        $State.Browser.running = $false
        throw
    }
    return $true
}

function Clear-IdsFinishedJob {
    Sync-IdsPolicyTransfer $State
    Sync-IdsFolderPicker $State
    Clear-IdsAssessmentJob $State
    Clear-IdsPolicyLoadJob $State
    if ($State.Browser.job -and $State.Browser.job.handle.IsCompleted) {
        $job = $State.Browser.job
        try { [void]$job.ps.EndInvoke($job.handle) } catch { }
        try { $job.ps.Dispose() } finally { $job.runspace.Dispose(); $State.Browser.job = $null }
    }
    if (-not $State.Job) { return }
    if ($State.Job.handle.IsCompleted) {
        try { [void]$State.Job.ps.EndInvoke($State.Job.handle) } catch { }
        try { $State.Job.ps.Dispose(); $State.Job.runspace.Dispose() } catch { }
        $State.Job = $null
    }
}

function Reset-IdsSessionState {
    <#  Wipes everything that belonged to the previous sign-in. Without this, the results
        pane, the export log and the output folder of one tenant stay visible to whoever
        signs in next — confusing at best, and a disclosure of another customer's estate at
        worst. The stale folder is also actively dangerous now that the exporter refuses to
        overwrite a different tenant's documentation. #>
    if ((Test-IdsWorkActive $State) -or $State.Browser.running) { throw 'An export, assessment or sign-in is still running.' }
    $offline = if ($State.Policies.sourceKind -eq 'offline') { $State.Policies.snapshot } else { $null }
    Reset-IdsAssessment $State
    Stop-IdsPolicyLoad $State
    $State.Auth = $null
    $State.Pending = $null
    $State.PolicyConsent = $null
    if ($offline) {
        $State.Policies.sourceKind = 'offline'; $State.Policies.snapshot = $offline
        $State.Policies.epoch = $State.Assessment.epoch
        $State.Policies.status = if (@($offline.collection.issues).Count -or @($offline.collection.documentationIssues).Count) { 'partial' } else { 'ready' }
        $State.Policies.percent = 100
    }

    $State.Export.log.Clear()
    $State.Export.summary = $null
    $State.Export.error = $null
    $State.Export.percent = 0
    $State.Export.phase = ''
    $State.Export.done = $false

    $State.Browser.status = ''
    $State.Browser.error = $null

    $State.Config.OutputPath = $State.Config.DefaultOutputPath
    $State.Config.Tenant = $State.Config.DefaultTenant
}

function Get-IdsAuthSummary {
    if (-not $State.Auth) { return @{ connected = $false } }
    $a = $State.Auth
    $client = ''
    foreach ($k in (Get-IdsClientCatalog).Keys) {
        if ((Get-IdsClientCatalog)[$k].id -eq $a.client_id) { $client = (Get-IdsClientCatalog)[$k].name }
    }
    if (-not $client) { $client = $a.client_id }
    return @{
        connected = $true
        account   = $a.account
        tenantId  = $a.tenant_id
        method    = $a.method
        client    = $client
        expiresAt = $(if ($a.expires_at) { ([datetime]$a.expires_at).ToString('o') } else { '' })
        scopes    = @(Get-IdsScopeReport -Auth $a)
    }
}

function Get-IdsOutputTree {
    <#  Shallow-ish listing of the generated repository for the results pane. #>
    param([string]$RootPath, [int]$Limit = 4000)
    if (-not (Test-Path -LiteralPath $RootPath)) { return @() }
    $items = @()
    $files = Get-ChildItem -LiteralPath $RootPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        Select-Object -First $Limit
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($RootPath.Length).TrimStart('\')
        $items += @{ path = ($rel -replace '\\', '/'); size = $f.Length }
    }
    return ($items | Sort-Object { $_.path })
}

function Resolve-IdsSafePath {
    <#  Prevents path traversal out of the export root when previewing files. #>
    param([string]$RootPath, [string]$Relative)
    if (-not $Relative) { return $null }
    $candidate = Join-Path $RootPath ($Relative -replace '/', '\')
    try { $full = [IO.Path]::GetFullPath($candidate) } catch { return $null }
    $rootFull = [IO.Path]::GetFullPath($RootPath)
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

# --- Headless export --------------------------------------------------------------------

function Invoke-IdsInteractiveSignIn {
    <#  Spins a short-lived loopback listener purely to catch the OAuth redirect. #>
    param([int]$ListenPort, [string]$TenantId, [string]$ClientId)
    $redirect = "http://localhost:$ListenPort"
    $pkce = New-IdsPkce
    $stateNonce = New-IdsNonce
    $url = Get-IdsAuthorizeUrl -Tenant $TenantId -ClientId $ClientId -RedirectUri $redirect `
        -CodeChallenge $pkce.challenge -State $stateNonce

    $listener = New-IdsHttpListener -Port $ListenPort
    try {
        Write-Host 'Opening your browser to sign in…' -ForegroundColor Cyan
        Write-Host "If it does not open, browse to:`n$url`n"
        Open-IdsBrowser -Url $url
        $ctx = $listener.GetContext()
        $q = Get-IdsQuery -Query $ctx.Request.Url.Query
        if ($q['error']) {
            Send-IdsText -Response $ctx.Response -Text "Sign-in failed: $($q['error_description'])" -ContentType 'text/html; charset=utf-8'
            throw "Sign-in failed: $($q['error']) - $($q['error_description'])"
        }
        if ($q['state'] -ne $stateNonce) {
            Send-IdsText -Response $ctx.Response -Text 'State mismatch.' -ContentType 'text/html; charset=utf-8'
            throw 'OAuth state mismatch - aborting.'
        }
        Send-IdsText -Response $ctx.Response -ContentType 'text/html; charset=utf-8' -Text @'
<!doctype html><meta charset="utf-8"><title>Signed in</title>
<body style="font-family:Segoe UI,sans-serif;padding:3rem;background:#0f1115;color:#e6e8ee">
<h2>Signed in.</h2><p>You can close this tab and return to the console.</p></body>
'@
        return (Complete-IdsAuthCode -Tenant $TenantId -ClientId $ClientId -Code $q['code'] -Verifier $pkce.verifier -RedirectUri $redirect)
    } finally {
        try { $listener.Stop(); $listener.Close() } catch { }
    }
}

if ($Export) {
    $clientId = (Get-IdsClient $Client).id
    switch ($Method) {
        'interactive' { $State.Auth = Invoke-IdsInteractiveSignIn -ListenPort $Port -TenantId $Tenant -ClientId $clientId }
        'browser'     { $State.Auth = Get-IdsTokenFromBrowser -Tenant $Tenant }
        'azurecli'    { $State.Auth = Get-IdsTokenFromAzureCli }
        'mggraph'     { $State.Auth = Connect-IdsMgGraph -Tenant $Tenant }
        'devicecode'  {
            $dc = Start-IdsDeviceCode -Tenant $Tenant -ClientId $clientId
            Write-Host ''
            Write-Host $dc.message -ForegroundColor Cyan
            Write-Host ''
            $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
            $interval = 5
            if ($dc.PSObject.Properties['interval']) { $interval = [int]$dc.interval }
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds $interval
                $r = Test-IdsDeviceCode -Tenant $Tenant -ClientId $clientId -DeviceCode $dc.device_code
                if ($r.status -eq 'ok') { $State.Auth = $r.auth; break }
                if ($r.status -eq 'slowdown') { $interval += 5; continue }
                if ($r.status -eq 'pending') { continue }
                throw "Device code sign-in failed: $($r.status) $($r.message)"
            }
            if (-not $State.Auth) { throw 'Device code sign-in timed out.' }
        }
    }
    Write-Host "Signed in as $($State.Auth.account)" -ForegroundColor Green

    $options = Get-IdsDefaultOptions
    $options.OutputPath = $OutputPath
    if ($Sections) { $options.Sections = $Sections }
    $options.IncludeRaw = -not $NoRawJson
    $options.IncludeRawFiles = -not $NoRawJson
    $options.IncludeScriptContent = -not $NoScriptContent
    $options.FrontMatter = -not $NoFrontMatter
    $options.AdoWikiOrder = -not $NoAdoOrder
    $options.GitCommit = [bool]$GitCommit
    $options.GitPush = [bool]$GitPush
    if ($GitMessage) { $options.GitMessage = $GitMessage }
    $options.GitRemoteUrl = $GitRemoteUrl
    $options.GitBranch = $GitBranch

    Reset-IdsGraphStats
    Start-IdsExport -State $State -Options $options
    if ($State.Export.error) { Write-Error $State.Export.error; exit 1 }
    $s = $State.Export.summary
    Write-Host ''
    Write-Host "Documentation written to $($s.root)" -ForegroundColor Green
    Write-Host ("  {0} created, {1} updated, {2} unchanged, {3} removed" -f $s.stats.created, $s.stats.updated, $s.stats.unchanged, $s.stats.deleted)
    exit 0
}

# --- Dashboard --------------------------------------------------------------------------

$listener = $null
try {
    $listener = New-IdsHttpListener -Port $Port
} catch {
    Write-Error "Could not bind to http://localhost:$Port/ - $($_.Exception.Message)"
    exit 1
}

$baseUrl = "http://localhost:$Port"
Write-Host ''
Write-Host ('  Intune Docs Studio {0} ({1})' -f $Build.version, $Build.channel) -ForegroundColor Cyan
Write-Host "  Dashboard: $baseUrl" -ForegroundColor Cyan
Write-Host '  To stop: use "Stop server" in the dashboard, or press Ctrl+C here.'
Write-Host ''
if (-not $NoBrowser) { Open-IdsBrowser -Url $baseUrl }

# With the async accept loop below, Ctrl+C reaches PowerShell between polls and unwinds the
# pipeline through the finally block, which releases the listener. No console event handler
# is needed — and registering one breaks startup when the process has no visible console.
$waiter = New-IdsContextWaiter -Listener $listener
$running = $true

try {
while ($running -and $listener.IsListening) {
    $context = Wait-IdsHttpContext -Waiter $waiter -TimeoutMs 250
    # No request within the timeout: loop so Ctrl+C and job cleanup get a turn.
    if (-not $context) { Clear-IdsFinishedJob; Sync-IdsPolicyLoad $State $Root; continue }

    $req = $context.Request
    $res = $context.Response
    $path = $req.Url.AbsolutePath.TrimEnd('/')
    if (-not $path) { $path = '/' }
    $query = Get-IdsQuery -Query $req.Url.Query
    Clear-IdsFinishedJob

    try {
        Sync-IdsPolicyLoad $State $Root
        if ($req.HttpMethod -eq 'POST' -and $path -in @('/api/signout', '/api/quit') -and
            ($State.Policies.running -or $State.Policies.job)) {
            Stop-IdsPolicyLoad $State
        }
        $identityMutation = ($req.HttpMethod -eq 'POST' -and $path -match '^/api/(signin/(interactive|devicecode|azurecli|mggraph|browser|browser/forget)|signout|quit)$') -or
            ($req.HttpMethod -eq 'GET' -and $path -eq '/api/signin/devicecode/poll')
        $oauthCallback = $req.HttpMethod -eq 'GET' -and $path -eq '/' -and ($query['code'] -or $query['error'])
        if (($identityMutation -or $oauthCallback) -and ((Test-IdsWorkActive $State) -or $State.Browser.running)) {
            if ($oauthCallback) { Send-IdsRedirect -Response $res -Location '/?signin=busy' }
            else { Send-IdsJson -Response $res -Object @{ error = 'An export, assessment or sign-in is still running.' } -Status 409 }
            continue
        }
        $policyRoute = Invoke-IdsPolicyRoute -Method $req.HttpMethod -Path $path -Request $req -State $State -Root $Root
        if ($policyRoute.handled) {
            Send-IdsJson -Response $res -Object $policyRoute.body -Status $policyRoute.status -Depth 64
            continue
        }
        $assessmentRoute = Invoke-IdsAssessmentRoute -Method $req.HttpMethod -Path $path -Request $req -State $State -Root $Root
        if ($assessmentRoute.handled) {
            Send-IdsJson -Response $res -Object $assessmentRoute.body -Status $assessmentRoute.status -Depth 64
            continue
        }
        switch -Regex ("$($req.HttpMethod) $path") {

            '^GET /$' {
                # Doubles as the OAuth redirect target.
                if ($query['code'] -or $query['error']) {
                    $pending = $State.Pending
                    if (-not $pending -or $pending.epoch -ne $State.Assessment.epoch) {
                        Send-IdsRedirect -Response $res -Location '/?signin=state-mismatch'
                        break
                    }
                    if ($query['error']) {
                        $State.Pending = @{ error = "$($query['error']): $($query['error_description'])" }
                        Send-IdsRedirect -Response $res -Location '/?signin=failed'
                        break
                    }
                    if (-not $pending -or $pending.state -ne $query['state']) {
                        Send-IdsRedirect -Response $res -Location '/?signin=state-mismatch'
                        break
                    }
                    try {
                        $auth = Complete-IdsAuthCode -Tenant $pending.tenant -ClientId $pending.clientId `
                            -Code $query['code'] -Verifier $pending.verifier -RedirectUri $pending.redirect
                        Reset-IdsSessionState
                        $State.Auth = $auth
                        Send-IdsRedirect -Response $res -Location '/?signin=ok'
                    } catch {
                        $State.Pending = @{ error = $_.Exception.Message }
                        Send-IdsRedirect -Response $res -Location '/?signin=failed'
                    }
                    break
                }
                Send-IdsStaticFile -Response $res -Path (Join-Path $Root 'web\index.html')
                break
            }

            '^GET /(app\.js|style\.css)$' {
                Send-IdsStaticFile -Response $res -Path (Join-Path $Root ('web\' + $path.TrimStart('/')))
                break
            }

            '^GET /api/health$' {
                Send-IdsJson -Response $res -Object @{ status = 'ok' }
                break
            }

            '^GET /api/version$' {
                Send-IdsJson -Response $res -Object $Build
                break
            }

            '^GET /api/state$' {
                $exp = $State.Export
                Send-IdsJson -Response $res -Object @{
                    build      = $Build
                    auth       = (Get-IdsAuthSummary)
                    policies   = (Get-IdsPolicySummary $State)
                    transfer   = @{ running = [bool]$State.PolicyTransfer.running
                        operation = $State.PolicyTransfer.operation; phase = $State.PolicyTransfer.phase }
                    outputPath = $State.Config.OutputPath
                    tenant     = $State.Config.Tenant
                    clients    = @(foreach ($k in (Get-IdsClientCatalog).Keys) {
                            @{ key = $k; name = (Get-IdsClientCatalog)[$k].name; note = (Get-IdsClientCatalog)[$k].note }
                        })
                    sections   = @(foreach ($k in (Get-IdsSectionCatalog).Keys) {
                            @{ key = $k; label = (Get-IdsSectionCatalog)[$k].label
                                available = ($State.Policies.snapshot.source.kind -ne 'offline' -or
                                    $k -in @('settingsCatalog', 'deviceConfigs', 'admx', 'compliance', 'endpointSecurity')) }
                        })
                    export     = @{
                        running = $exp.running; done = $exp.done; error = $exp.error
                        percent = $exp.percent; phase = $exp.phase
                        summary = $exp.summary
                    }
                    pendingError = $(if ($State.Pending -and $State.Pending.error) { $State.Pending.error } else { $null })
                }
                break
            }

            '^POST /api/policies/reload$' {
                if (-not $State.Auth) { Send-IdsJson -Response $res -Object @{ error = 'Not signed in.' } -Status 401; break }
                if ($req.Headers['Origin'] -cne $baseUrl -or $req.Headers['Host'] -cne ([uri]$baseUrl).Authority) {
                    Send-IdsJson -Response $res -Object @{ error = 'Same-origin request required.' } -Status 403; break
                }
                if ($req.ContentType -notmatch '^(?i:application/json)(?:\s*;\s*charset\s*=\s*(?i:utf-8))?\s*$') {
                    Send-IdsJson -Response $res -Object @{ error = 'Content-Type must be application/json.' } -Status 415; break
                }
                if (Test-IdsWorkActive $State) {
                    Send-IdsJson -Response $res -Object @{ error = 'Policy loading, export, assessment or sign-in is already running.' } -Status 409; break
                }
                $body = Read-IdsAssessmentRequestJson $req 4KB
                if ($State.Policies.snapshot -and $body.replace -ne $true) {
                    Send-IdsJson -Response $res -Object @{ error = 'Confirm replacement of the active policy source before loading live policies.' } -Status 409; break
                }
                Reset-IdsAssessment $State
                if (Start-IdsPolicyLoad $State $Root) {
                    Send-IdsJson -Response $res -Object @{ started = $true } -Status 202
                } else {
                    Send-IdsJson -Response $res -Object @{ error = $State.Policies.error } -Status 500
                }
                break
            }

            '^POST /api/signin/interactive$' {
                $body = Read-IdsRequestJson -Request $req
                $t = 'organizations'
                if ($body.tenant) { $t = $body.tenant }
                $c = 'graphcli'
                if ($body.client) { $c = $body.client }
                $pkce = New-IdsPkce
                $nonce = New-IdsNonce
                $redirect = $baseUrl
                $State.Pending = @{
                    verifier = $pkce.verifier; state = $nonce; tenant = $t
                    clientId = (Get-IdsClient $c).id; redirect = $redirect; error = $null
                    epoch = $State.Assessment.epoch
                }
                $url = Get-IdsAuthorizeUrl -Tenant $t -ClientId $State.Pending.clientId -RedirectUri $redirect `
                    -CodeChallenge $pkce.challenge -State $nonce
                Send-IdsJson -Response $res -Object @{ url = $url }
                break
            }

            '^POST /api/signin/devicecode$' {
                $body = Read-IdsRequestJson -Request $req
                $t = 'organizations'
                if ($body.tenant) { $t = $body.tenant }
                $c = 'graphcli'
                if ($body.client) { $c = $body.client }
                try {
                    $cid = (Get-IdsClient $c).id
                    $dc = Start-IdsDeviceCode -Tenant $t -ClientId $cid
                    $State.Pending = @{
                        deviceCode = $dc.device_code; tenant = $t; clientId = $cid
                        interval = [int]$dc.interval; error = $null
                        epoch = $State.Assessment.epoch
                    }
                    Send-IdsJson -Response $res -Object @{
                        userCode = $dc.user_code; verificationUri = $dc.verification_uri; message = $dc.message
                    }
                } catch {
                    Send-IdsJson -Response $res -Object @{ error = $_.Exception.Message } -Status 400
                }
                break
            }

            '^GET /api/signin/devicecode/poll$' {
                if (-not $State.Pending -or -not $State.Pending.deviceCode -or $State.Pending.epoch -ne $State.Assessment.epoch) {
                    Send-IdsJson -Response $res -Object @{ status = 'none' }
                    break
                }
                $r = Test-IdsDeviceCode -Tenant $State.Pending.tenant -ClientId $State.Pending.clientId -DeviceCode $State.Pending.deviceCode
                if ($r.status -eq 'ok') {
                    Reset-IdsSessionState
                    $State.Auth = $r.auth
                    $State.Pending = $null
                    Send-IdsJson -Response $res -Object @{ status = 'ok' }
                } else {
                    Send-IdsJson -Response $res -Object @{ status = $r.status; message = $r.message }
                }
                break
            }

            '^POST /api/signin/azurecli$' {
                try {
                    $auth = Get-IdsTokenFromAzureCli
                    Reset-IdsSessionState
                    $State.Auth = $auth
                    Send-IdsJson -Response $res -Object @{ ok = $true }
                } catch {
                    Send-IdsJson -Response $res -Object @{ error = $_.Exception.Message } -Status 400
                }
                break
            }

            '^POST /api/signin/mggraph$' {
                try {
                    $body = Read-IdsRequestJson -Request $req
                    $t = ''
                    if ($body.tenant) { $t = $body.tenant }
                    $auth = Connect-IdsMgGraph -Tenant $t
                    Reset-IdsSessionState
                    $State.Auth = $auth
                    Send-IdsJson -Response $res -Object @{ ok = $true }
                } catch {
                    Send-IdsJson -Response $res -Object @{ error = $_.Exception.Message } -Status 400
                }
                break
            }

            '^POST /api/signin/browser$' {
                $body = Read-IdsRequestJson -Request $req
                $t = $State.Config.Tenant
                if ($body.tenant) { $t = $body.tenant }
                $force = $false
                if ($body.PSObject.Properties['forcePicker']) { $force = [bool]$body.forcePicker }
                [void](Start-IdsBrowserSignIn -TenantId $t -ForcePicker $force)
                Send-IdsJson -Response $res -Object @{ started = $true }
                break
            }

            '^GET /api/signin/browser/status$' {
                Send-IdsJson -Response $res -Object @{
                    running = $State.Browser.running
                    status  = $State.Browser.status
                    error   = $State.Browser.error
                    done    = ($null -ne $State.Auth)
                }
                break
            }

            '^POST /api/signin/browser/forget$' {
                try {
                    Clear-IdsBrowserProfile
                    Reset-IdsSessionState
                    Send-IdsJson -Response $res -Object @{ ok = $true }
                } catch {
                    Send-IdsJson -Response $res -Object @{ error = $_.Exception.Message } -Status 400
                }
                break
            }

            '^POST /api/signout$' {
                # Never sign out mid-export: the running job still holds the token and would
                # fail halfway, leaving a partial tree behind.
                if (Test-IdsWorkActive $State) {
                    Send-IdsJson -Response $res -Object @{ error = 'An export is still running. Wait for it to finish before signing out.' } -Status 409
                    break
                }
                Reset-IdsSessionState
                Send-IdsJson -Response $res -Object @{ ok = $true; outputPath = $State.Config.OutputPath; tenant = $State.Config.Tenant }
                break
            }

            '^GET /api/probe$' {
                if (-not $State.Auth) { Send-IdsJson -Response $res -Object @{ error = 'Not signed in' } -Status 401; break }
                Send-IdsJson -Response $res -Object (Test-IdsGraphConnection)
                break
            }

            '^GET /api/checkfolder$' {
                $path = $query['path']
                if (-not $path) { $path = $State.Config.OutputPath }
                $result = @{ conflict = $null; suggestion = $null }
                if ($State.Policies.snapshot) {
                    try {
                        $snapshot = Get-IdsLoadedPolicies $State
                        $conn = @{ tenantId = $snapshot.tenant.id; organization = $snapshot.tenant.name }
                        $c = Test-IdsOutputFolderTenant -Root $path -TenantId $conn.tenantId -TenantName $conn.organization
                        if ($c) {
                            $result.conflict = $c
                            $result.suggestion = Get-IdsFolderSuggestion -CurrentPath $path -TenantName $conn.organization -TenantId $conn.tenantId
                        }
                    } catch { }
                }
                Send-IdsJson -Response $res -Object $result
                break
            }

            '^POST /api/export$' {
                try { Assert-IdsLocalJsonRequest $req $State }
                catch [UnauthorizedAccessException] { Send-IdsJson -Response $res -Object @{ error = $_.Exception.Message } -Status 403; break }
                catch [NotSupportedException] { Send-IdsJson -Response $res -Object @{ error = $_.Exception.Message } -Status 415; break }
                if (-not $State.Auth -and -not $State.Policies.snapshot) { Send-IdsJson -Response $res -Object @{ error = 'Load or import policies first.' } -Status 401; break }
                if ((Test-IdsWorkActive $State) -or $State.Browser.running) { Send-IdsJson -Response $res -Object @{ error = 'An export, assessment or sign-in is already running' } -Status 409; break }
                try { $null = Get-IdsLoadedPolicies $State } catch {
                    Send-IdsJson -Response $res -Object @{ error = $_.Exception.Message } -Status 409; break
                }

                $body = Read-IdsRequestJson -Request $req
                $options = Get-IdsDefaultOptions
                if ($body.outputPath) { $options.OutputPath = [string]$body.outputPath; $State.Config.OutputPath = $options.OutputPath }
                if ($body.sections) { $options.Sections = @($body.sections) }
                if ($State.Policies.snapshot.source.kind -eq 'offline' -and @($options.Sections | Where-Object {
                    $_ -notin @('settingsCatalog', 'deviceConfigs', 'admx', 'compliance', 'endpointSecurity')
                }).Count) {
                    Send-IdsJson -Response $res -Object @{ error = 'Offline documentation supports only the five policy families; apps, scripts and other live sections are unavailable.' } -Status 400; break
                }
                foreach ($pair in @(
                        @('includeRaw', 'IncludeRaw'), @('includeRaw', 'IncludeRawFiles'),
                        @('includeScriptContent', 'IncludeScriptContent'), @('frontMatter', 'FrontMatter'),
                        @('adoWikiOrder', 'AdoWikiOrder'), @('gitCommit', 'GitCommit'), @('gitPush', 'GitPush'),
                        @('allowTenantOverwrite', 'AllowTenantOverwrite'))) {
                    if ($body.PSObject.Properties[$pair[0]]) { $options[$pair[1]] = [bool]$body.($pair[0]) }
                }
                if ($body.gitMessage) { $options.GitMessage = [string]$body.gitMessage }
                if ($body.gitRemoteUrl) { $options.GitRemoteUrl = [string]$body.gitRemoteUrl }
                if ($body.gitBranch) { $options.GitBranch = [string]$body.gitBranch }
                try {
                    Assert-IdsGitOptions -Options $options
                } catch {
                    Send-IdsJson -Response $res -Object @{ error = $_.Exception.Message } -Status 400
                    break
                }

                [void](Start-IdsExportJob -Options $options)
                Send-IdsJson -Response $res -Object @{ started = $true }
                break
            }

            '^GET /api/export/log$' {
                $from = 0
                if ($query['from']) { [void][int]::TryParse($query['from'], [ref]$from) }
                $log = @($State.Export.log)
                $slice = @()
                if ($from -lt $log.Count) { $slice = $log[$from..($log.Count - 1)] }
                Send-IdsJson -Response $res -Object @{
                    total   = $log.Count
                    entries = $slice
                    percent = $State.Export.percent
                    phase   = $State.Export.phase
                    running = $State.Export.running
                    done    = $State.Export.done
                    error   = $State.Export.error
                    summary = $State.Export.summary
                }
                break
            }

            '^GET /api/files$' {
                $rootPath = $State.Config.OutputPath
                if ($State.Export.summary -and $State.Export.summary.root) { $rootPath = $State.Export.summary.root }
                Send-IdsJson -Response $res -Object @{ root = $rootPath; files = @(Get-IdsOutputTree -RootPath $rootPath) }
                break
            }

            '^GET /api/file$' {
                $rootPath = $State.Config.OutputPath
                if ($State.Export.summary -and $State.Export.summary.root) { $rootPath = $State.Export.summary.root }
                $full = Resolve-IdsSafePath -RootPath $rootPath -Relative $query['path']
                if (-not $full -or -not (Test-Path -LiteralPath $full)) {
                    Send-IdsJson -Response $res -Object @{ error = 'Not found' } -Status 404
                    break
                }
                Send-IdsJson -Response $res -Object @{ path = $query['path']; content = ([IO.File]::ReadAllText($full)) }
                break
            }

            '^POST /api/open$' {
                $rootPath = $State.Config.OutputPath
                if ($State.Export.summary -and $State.Export.summary.root) { $rootPath = $State.Config.OutputPath = $State.Export.summary.root }
                try { Start-Process 'explorer.exe' -ArgumentList $rootPath | Out-Null } catch { }
                Send-IdsJson -Response $res -Object @{ ok = $true }
                break
            }

            '^POST /api/quit$' {
                if (Test-IdsWorkActive $State) {
                    Send-IdsJson -Response $res -Object @{ error = 'An export is still running.' } -Status 409
                    break
                }
                Send-IdsJson -Response $res -Object @{ ok = $true }
                $running = $false
                break
            }

            default {
                Send-IdsJson -Response $res -Object @{ error = 'Not found' } -Status 404
            }
        }
    } catch {
        try { Send-IdsJson -Response $res -Object @{ error = $_.Exception.Message } -Status 500 } catch { }
    }
}
} finally {
    # Runs on Ctrl+C as well as a normal exit, so the port is always released.
    Stop-IdsHttpListener -Listener $listener
    try { Stop-IdsAssessmentJob $State } catch { }
    try { Stop-IdsPolicyLoad $State } catch { }
    try { Stop-IdsPolicyTransfer $State } catch { }
    try { Stop-IdsFolderPicker $State } catch { }
    if ($State.Browser.job) {
        try { $State.Browser.job.ps.Stop() } catch { }
        try { $State.Browser.job.ps.Dispose(); $State.Browser.job.runspace.Dispose() } catch { }
        $State.Browser.job = $null
    }
    if ($State.Job) {
        try { $State.Job.ps.Stop() } catch { }
        try { $State.Job.ps.Dispose(); $State.Job.runspace.Dispose() } catch { }
    }
    Write-Host ''
    Write-Host 'Intune Docs Studio stopped.' -ForegroundColor Cyan
}
