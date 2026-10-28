<#
    Auth.ps1 — delegated Microsoft Graph authentication WITHOUT an Entra ID app registration.

    Every client id below is a Microsoft first-party PUBLIC client that already exists as a
    service principal in essentially every tenant. We never create an app, never store a
    secret, and never request application permissions. The export therefore runs strictly as
    the signed-in administrator, honouring their Intune RBAC scope.

    Supported methods (best first):
      interactive  Authorization Code + PKCE against http://localhost:<port>  (loopback)
      devicecode   Device Code flow — for hosts without a browser / RDP sessions
      azurecli     Reuse an existing `az login` session
      mggraph      Reuse an existing Connect-MgGraph session (transport mode)
#>

# --- First-party public clients --------------------------------------------------------

$script:IdsClients = [ordered]@{
    graphcli = @{
        id   = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
        name = 'Microsoft Graph Command Line Tools'
        note = 'Used by the Microsoft.Graph PowerShell SDK. Loopback + device code capable.'
    }
    azurecli = @{
        id   = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        name = 'Microsoft Azure CLI'
        note = 'Pre-authorised for Microsoft Graph in the majority of tenants.'
    }
    intuneps = @{
        id   = 'd1ddf0e4-d672-4dae-b554-9d5bdfd93547'
        name = 'Microsoft Intune PowerShell'
        note = 'Legacy Intune client. Frequently already consented in long-lived tenants.'
    }
}

# Read-only delegated scopes. Nothing here can change tenant state.
$script:IdsScopes = @(
    'https://graph.microsoft.com/DeviceManagementConfiguration.Read.All'
    'https://graph.microsoft.com/DeviceManagementApps.Read.All'
    'https://graph.microsoft.com/DeviceManagementServiceConfig.Read.All'
    'https://graph.microsoft.com/DeviceManagementRBAC.Read.All'
    'https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All'
    'https://graph.microsoft.com/Group.Read.All'
    'offline_access'
)

# Scope -> what breaks without it. Surfaced in the dashboard when consent is partial.
$script:IdsScopeUsage = [ordered]@{
    'DeviceManagementConfiguration.Read.All'  = 'Configuration profiles, settings catalog, compliance, endpoint security'
    'DeviceManagementApps.Read.All'           = 'Applications, app protection and app configuration policies'
    'DeviceManagementServiceConfig.Read.All'  = 'Enrollment, Autopilot, ESP, terms, notification templates'
    'DeviceManagementRBAC.Read.All'           = 'Roles, scope tags'
    'DeviceManagementManagedDevices.Read.All' = 'Device counts and remediation script state'
    'Group.Read.All'                          = 'Resolving assignment group ids to display names'
}

function Get-IdsClient {
    param([string]$Name = 'graphcli')
    if ($script:IdsClients.Contains($Name)) { return $script:IdsClients[$Name] }
    return $script:IdsClients['graphcli']
}

function Get-IdsClientCatalog { return $script:IdsClients }
function Get-IdsScopeList { return $script:IdsScopes }
function Get-IdsScopeUsage { return $script:IdsScopeUsage }

# --- JWT helpers ------------------------------------------------------------------------

function ConvertFrom-IdsJwt {
    <#  Decodes the payload of a JWT without validating it. We only ever use this for
        display (who am I, which tenant, which scopes were actually granted). #>
    param([string]$Token)
    if (-not $Token) { return $null }
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $p = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) {
        2 { $p += '==' }
        3 { $p += '=' }
        1 { return $null }
    }
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

# --- PKCE -------------------------------------------------------------------------------

function New-IdsPkce {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return @{ verifier = $verifier; challenge = $challenge }
}

function New-IdsNonce {
    $bytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# --- Authorization Code + PKCE (loopback) ----------------------------------------------

function Get-IdsAuthorizeUrl {
    <#  Builds the /authorize URL. RedirectUri MUST be a bare loopback origin such as
        http://localhost:7654 — Entra ID matches loopback redirects ignoring the port,
        but the PATH must match the registered value (which is empty). #>
    param(
        [string]$Tenant = 'organizations',
        [string]$ClientId,
        [string]$RedirectUri,
        [string[]]$Scopes = $script:IdsScopes,
        [string]$CodeChallenge,
        [string]$State,
        [string]$Prompt = 'select_account'
    )
    $q = [ordered]@{
        client_id             = $ClientId
        response_type         = 'code'
        redirect_uri          = $RedirectUri
        response_mode         = 'query'
        scope                 = ($Scopes -join ' ')
        state                 = $State
        code_challenge        = $CodeChallenge
        code_challenge_method = 'S256'
        prompt                = $Prompt
    }
    $pairs = foreach ($k in $q.Keys) { '{0}={1}' -f $k, [uri]::EscapeDataString([string]$q[$k]) }
    return "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/authorize?" + ($pairs -join '&')
}

function Invoke-IdsTokenEndpoint {
    param([string]$Tenant = 'organizations', [hashtable]$Body)
    $uri = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
    try {
        return Invoke-RestMethod -Method POST -Uri $uri -Body $Body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } catch {
        # The error body lives in different places on Windows PowerShell 5.1 (WebException)
        # and PowerShell 7 (HttpResponseException), so try both.
        $raw = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $raw = $_.ErrorDetails.Message }
        if (-not $raw) {
            try {
                $resp = $_.Exception.Response
                if ($resp -is [System.Net.HttpWebResponse]) {
                    $sr = New-Object IO.StreamReader($resp.GetResponseStream())
                    try { $raw = $sr.ReadToEnd() } finally { $sr.Dispose() }
                }
            } catch { }
        }
        $detail = $null
        if ($raw) { try { $detail = $raw | ConvertFrom-Json } catch { } }
        if ($detail -and $detail.PSObject.Properties['error']) {
            $err = New-Object System.Exception ("$($detail.error): $($detail.error_description)")
            $err | Add-Member -NotePropertyName OAuthError -NotePropertyValue $detail.error -Force
            throw $err
        }
        throw
    }
}

function New-IdsAuthState {
    param($TokenResponse, [string]$ClientId, [string]$Tenant, [string]$Method)
    $claims = ConvertFrom-IdsJwt $TokenResponse.access_token
    $granted = @()
    if ($claims -and $claims.scp) { $granted = @($claims.scp -split ' ') }
    $refresh = $null
    if ($TokenResponse.PSObject.Properties['refresh_token']) { $refresh = $TokenResponse.refresh_token }
    $expiresIn = 3600
    if ($TokenResponse.PSObject.Properties['expires_in']) { $expiresIn = [int]$TokenResponse.expires_in }

    $account = ''
    if ($claims) {
        if ($claims.PSObject.Properties['upn'] -and $claims.upn) { $account = $claims.upn }
        elseif ($claims.PSObject.Properties['preferred_username'] -and $claims.preferred_username) { $account = $claims.preferred_username }
        elseif ($claims.PSObject.Properties['unique_name'] -and $claims.unique_name) { $account = $claims.unique_name }
    }
    $tid = $Tenant
    if ($claims -and $claims.PSObject.Properties['tid'] -and $claims.tid) { $tid = $claims.tid }

    return @{
        access_token  = $TokenResponse.access_token
        refresh_token = $refresh
        expires_at    = (Get-Date).ToUniversalTime().AddSeconds($expiresIn - 120)
        client_id     = $ClientId
        tenant        = $Tenant
        tenant_id     = $tid
        account       = $account
        method        = $Method
        granted       = $granted
        transport     = 'token'
    }
}

function Complete-IdsAuthCode {
    param(
        [string]$Tenant = 'organizations',
        [string]$ClientId,
        [string]$Code,
        [string]$Verifier,
        [string]$RedirectUri
    )
    $body = @{
        client_id     = $ClientId
        grant_type    = 'authorization_code'
        code          = $Code
        redirect_uri  = $RedirectUri
        code_verifier = $Verifier
        scope         = ($script:IdsScopes -join ' ')
    }
    $r = Invoke-IdsTokenEndpoint -Tenant $Tenant -Body $body
    return (New-IdsAuthState -TokenResponse $r -ClientId $ClientId -Tenant $Tenant -Method 'interactive')
}

# --- Device code ------------------------------------------------------------------------

function Start-IdsDeviceCode {
    param([string]$Tenant = 'organizations', [string]$ClientId, [string[]]$Scopes = $script:IdsScopes)
    $uri = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/devicecode"
    $body = @{ client_id = $ClientId; scope = ($Scopes -join ' ') }
    return Invoke-RestMethod -Method POST -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
}

function Test-IdsDeviceCode {
    <#  Single non-blocking poll. Returns @{ status = pending|declined|expired|slowdown|ok; auth = <state> } #>
    param([string]$Tenant = 'organizations', [string]$ClientId, [string]$DeviceCode)
    $body = @{
        client_id   = $ClientId
        grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
        device_code = $DeviceCode
    }
    try {
        $r = Invoke-IdsTokenEndpoint -Tenant $Tenant -Body $body
        return @{ status = 'ok'; auth = (New-IdsAuthState -TokenResponse $r -ClientId $ClientId -Tenant $Tenant -Method 'devicecode') }
    } catch {
        $code = ''
        if ($_.Exception.PSObject.Properties['OAuthError']) { $code = $_.Exception.OAuthError }
        switch ($code) {
            'authorization_pending'  { return @{ status = 'pending' } }
            'slow_down'              { return @{ status = 'slowdown' } }
            'authorization_declined' { return @{ status = 'declined'; message = $_.Exception.Message } }
            'expired_token'          { return @{ status = 'expired'; message = $_.Exception.Message } }
            default                  { return @{ status = 'error'; message = $_.Exception.Message } }
        }
    }
}

# --- Existing sessions ------------------------------------------------------------------

function Get-IdsTokenFromAzureCli {
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) { throw 'Azure CLI (az) was not found on PATH.' }

    $raw = & az account get-access-token --scope 'https://graph.microsoft.com/.default' -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Older Azure CLI builds only understand --resource.
        $raw = & az account get-access-token --resource 'https://graph.microsoft.com' -o json 2>&1
    }
    if ($LASTEXITCODE -ne 0) { throw "az account get-access-token failed: $raw" }

    $j = ($raw | Out-String) | ConvertFrom-Json
    $claims = ConvertFrom-IdsJwt $j.accessToken
    $granted = @()
    if ($claims -and $claims.scp) { $granted = @($claims.scp -split ' ') }
    $expires = (Get-Date).ToUniversalTime().AddMinutes(50)
    if ($j.PSObject.Properties['expires_on']) {
        try { $expires = [DateTimeOffset]::FromUnixTimeSeconds([int64]$j.expires_on).UtcDateTime.AddMinutes(-2) } catch { }
    }
    $account = ''
    if ($claims) {
        if ($claims.PSObject.Properties['upn'] -and $claims.upn) { $account = $claims.upn }
        elseif ($claims.PSObject.Properties['preferred_username']) { $account = $claims.preferred_username }
    }
    $tid = ''
    if ($claims -and $claims.PSObject.Properties['tid']) { $tid = $claims.tid }
    return @{
        access_token  = $j.accessToken
        refresh_token = $null
        expires_at    = $expires
        client_id     = (Get-IdsClient 'azurecli').id
        tenant        = $tid
        tenant_id     = $tid
        account       = $account
        method        = 'azurecli'
        granted       = $granted
        transport     = 'token'
    }
}

function Connect-IdsMgGraph {
    <#  Reuses (or establishes) a Microsoft.Graph PowerShell session. The SDK does not expose
        the raw bearer token, so we flag transport='mggraph' and route every Graph call
        through Invoke-MgGraphRequest instead. #>
    param([string]$Tenant)
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication module is not installed. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        $shortScopes = @($script:IdsScopes | Where-Object { $_ -ne 'offline_access' } | ForEach-Object { $_ -replace '^https://graph\.microsoft\.com/', '' })
        $p = @{ Scopes = $shortScopes; NoWelcome = $true; ErrorAction = 'Stop' }
        if ($Tenant -and $Tenant -ne 'organizations') { $p['TenantId'] = $Tenant }
        Connect-MgGraph @p
        $ctx = Get-MgContext -ErrorAction Stop
    }
    $granted = @()
    if ($ctx.Scopes) { $granted = @($ctx.Scopes) }
    return @{
        access_token  = $null
        refresh_token = $null
        expires_at    = (Get-Date).ToUniversalTime().AddHours(1)
        client_id     = $ctx.ClientId
        tenant        = $ctx.TenantId
        tenant_id     = $ctx.TenantId
        account       = $ctx.Account
        method        = 'mggraph'
        granted       = $granted
        transport     = 'mggraph'
    }
}

# --- Refresh ----------------------------------------------------------------------------

function Update-IdsToken {
    <#  Refreshes an access token in place when a refresh_token is available. Returns the
        (possibly unchanged) auth state. Callers should treat the result as authoritative. #>
    param([hashtable]$Auth)
    if (-not $Auth) { return $null }
    if ($Auth.transport -eq 'mggraph') { return $Auth }
    if ($Auth.expires_at -and $Auth.expires_at -gt (Get-Date).ToUniversalTime()) { return $Auth }

    if ($Auth.method -eq 'azurecli') { return (Get-IdsTokenFromAzureCli) }
    if (-not $Auth.refresh_token) { return $Auth }

    $body = @{
        client_id     = $Auth.client_id
        grant_type    = 'refresh_token'
        refresh_token = $Auth.refresh_token
        scope         = ($script:IdsScopes -join ' ')
    }
    $tenant = $Auth.tenant
    if (-not $tenant) { $tenant = 'organizations' }
    $r = Invoke-IdsTokenEndpoint -Tenant $tenant -Body $body
    $new = New-IdsAuthState -TokenResponse $r -ClientId $Auth.client_id -Tenant $tenant -Method $Auth.method
    if (-not $new.refresh_token) { $new.refresh_token = $Auth.refresh_token }
    return $new
}

# --- Consent diagnostics ----------------------------------------------------------------

function Get-IdsScopeReport {
    <#  Compares the scopes present in the token against what the exporter needs.

        A portal-captured token carries whatever scopes the admin center asked for, which are
        often broader (ReadWrite) or differently named than our read-only list. Treat a
        matching ReadWrite scope as satisfying the read requirement, and never claim a
        permission is missing when an equivalent one is present. #>
    param([hashtable]$Auth)
    $report = @()
    if (-not $Auth) { return $report }

    $granted = @()
    foreach ($g in @($Auth.granted)) {
        if ($g) { $granted += ($g -replace '^https://graph\.microsoft\.com/', '') }
    }
    # A tenant-wide directory read or full Graph delegation covers everything below.
    $wildcard = ($granted -contains 'Directory.Read.All' -or $granted -contains 'Directory.AccessAsUser.All' -or
        $granted -contains 'user_impersonation' -or $granted -contains '.default')

    foreach ($k in $script:IdsScopeUsage.Keys) {
        $family = ($k -replace '\.Read\.All$', '')
        $has = $wildcard
        if (-not $has) {
            foreach ($g in $granted) {
                if ($g -eq $k -or $g -eq "$family.ReadWrite.All" -or $g -like "$family.*") { $has = $true; break }
            }
        }
        $report += [pscustomobject]@{
            scope   = $k
            granted = $has
            impact  = $script:IdsScopeUsage[$k]
        }
    }
    return $report
}
