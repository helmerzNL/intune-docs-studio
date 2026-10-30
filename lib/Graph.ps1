. (Join-Path $PSScriptRoot 'Localization.ps1')

<#
    Graph.ps1 — transport-aware Microsoft Graph client.

    Two transports are supported:
      token    raw bearer token obtained by Auth.ps1 (interactive / device code / az cli)
      mggraph  routed through Invoke-MgGraphRequest, reusing an existing Connect-MgGraph session

    Everything the exporter needs is read-only. Handles paging, throttling with Retry-After,
    transparent token refresh, and $batch for the many small assignment lookups.
#>

$script:IdsGraphState = $null
$script:IdsGraphStats = @{ requests = 0; retries = 0; throttled = 0; failures = 0 }

function Initialize-IdsGraph {
    <#  $StateHolder is a hashtable with an 'Auth' key. We keep the reference so a refreshed
        token is visible to every other component (dashboard, exporter runspace). #>
    param([hashtable]$StateHolder)
    $script:IdsGraphState = $StateHolder
}

function Get-IdsGraphStats { return $script:IdsGraphStats }
function Reset-IdsGraphStats { $script:IdsGraphStats = @{ requests = 0; retries = 0; throttled = 0; failures = 0 } }

function Test-IdsGraphAuthenticationFailure {
    param([Exception]$Exception)
    # Refresh failures can precede the HTTP wrapper and have no StatusCode.
    # Use structured metadata only; never inspect provider messages or bodies.
    return [bool]($Exception.StatusCode -eq 401 -or
        ($Exception.PSObject.Properties['OAuthError'] -and $Exception.OAuthError))
}

function Get-IdsGraphAuth {
    if (-not $script:IdsGraphState) { throw (Get-IdsText -Key 'text.graph_client_not_initialised_call_initialize_idsgraph_first') }
    $auth = $script:IdsGraphState.Auth
    if (-not $auth) { throw (Get-IdsText -Key 'text.not_signed_in') }
    if ($auth.transport -ne 'mggraph' -and $auth.expires_at -le (Get-Date).ToUniversalTime()) {
        $refreshed = Update-IdsToken -Auth $auth
        if ($refreshed) {
            $script:IdsGraphState.Auth = $refreshed
            $auth = $refreshed
        }
    }
    return $auth
}

function Resolve-IdsGraphUri {
    param([string]$Path, [string]$Version = 'beta')
    if ($Path -match '^https?://') { return $Path }
    if ($Path.Length -gt 0 -and $Path[0] -ne '/') { $Path = '/' + $Path }
    return "https://graph.microsoft.com/$Version$Path"
}

function Invoke-IdsGraphRaw {
    <#  Single HTTP call with throttling/transient retry. Returns the deserialised body. #>
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        $Body,
        [int]$MaxRetry = 5
    )
    $auth = Get-IdsGraphAuth
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $script:IdsGraphStats.requests++
            if ($auth.transport -eq 'mggraph') {
                $p = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
                if ($null -ne $Body) { $p['Body'] = ($Body | ConvertTo-Json -Depth 20) }
                return Invoke-MgGraphRequest @p
            }
            $headers = @{
                Authorization    = 'Bearer ' + $auth.access_token
                'Content-Type'   = 'application/json'
                ConsistencyLevel = 'eventual'
            }
            $p = @{ Uri = $Uri; Method = $Method; Headers = $headers; UseBasicParsing = $true; ErrorAction = 'Stop' }
            if ($null -ne $Body) { $p['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress) }
            $resp = Invoke-WebRequest @p
            $content = $resp.Content
            if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
            if (-not $content) { return $null }
            return ($content | ConvertFrom-Json)
        } catch {
            $status = 0
            try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }

            if (($status -eq 429 -or $status -eq 503 -or $status -eq 504) -and $attempt -le $MaxRetry) {
                $script:IdsGraphStats.throttled++
                $script:IdsGraphStats.retries++
                $wait = [Math]::Min(60, [Math]::Pow(2, $attempt))
                try {
                    $ra = $_.Exception.Response.Headers['Retry-After']
                    if ($ra) { $wait = [int]$ra }
                } catch { }
                Start-Sleep -Seconds $wait
                continue
            }
            if ($status -eq 401 -and $attempt -le 2 -and $auth.transport -ne 'mggraph') {
                # Only worth retrying if a refresh actually produced a different token.
                $refreshed = Update-IdsToken -Auth ($script:IdsGraphState.Auth)
                if ($refreshed -and $refreshed.access_token -and $refreshed.access_token -ne $auth.access_token) {
                    $script:IdsGraphState.Auth = $refreshed
                    $auth = $refreshed
                    continue
                }
            }
            $script:IdsGraphStats.failures++
            $msg = $_.Exception.Message
            $err = New-Object System.Exception ((Get-IdsText -Key 'text.graph_arg0_arg1_failed_arg2_arg3' -Arguments @{ arg0 = ($Method); arg1 = ($Uri); arg2 = ($status); arg3 = ($msg) }))
            $err | Add-Member -NotePropertyName StatusCode -NotePropertyValue $status -Force
            throw $err
        }
    }
}

function Invoke-IdsGraph {
    <#  .SYNOPSIS Fetch a Graph resource.
        -All      follow @odata.nextLink and return the flattened value collection
        -Tolerant return $null instead of throwing on 4xx (used for optional endpoints that
                  do not exist in every tenant / licence combination) #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Method = 'GET',
        $Body,
        [string]$Version = 'beta',
        [switch]$All,
        [switch]$Tolerant
    )
    $uri = Resolve-IdsGraphUri -Path $Path -Version $Version
    try {
        if (-not $All) { return (Invoke-IdsGraphRaw -Uri $uri -Method $Method -Body $Body) }

        $items = New-Object System.Collections.ArrayList
        $next = $uri
        $guard = 0
        while ($next -and $guard -lt 500) {
            $guard++
            $page = Invoke-IdsGraphRaw -Uri $next -Method 'GET'
            if ($null -eq $page) { break }
            if ($page.PSObject.Properties['value'] -and $null -ne $page.value) {
                foreach ($v in @($page.value)) { [void]$items.Add($v) }
            } else {
                [void]$items.Add($page)
                break
            }
            $next = $null
            if ($page.PSObject.Properties['@odata.nextLink']) { $next = $page.'@odata.nextLink' }
        }
        return $items.ToArray()
    } catch {
        $status = 0
        if ($_.Exception.PSObject.Properties['StatusCode']) { $status = [int]$_.Exception.StatusCode }
        # Tolerate only "this endpoint does not apply to this tenant" style answers.
        # Transient failures (5xx, throttling, network) must propagate, otherwise a blip
        # would look like "these objects no longer exist" and prune real documentation.
        if ($Tolerant -and @(400, 403, 404, 405, 501) -contains $status) { return $null }
        throw
    }
}

function Invoke-IdsGraphBatch {
    <#  JSON batching — up to 20 requests per round trip. Input is an array of hashtables:
          @{ id = 'unique'; url = '/deviceManagement/...'; method = 'GET' }
        Returns a hashtable keyed by id containing @{ status = <int>; body = <object> }.
        Batch failures never throw; the caller inspects the status per entry. #>
    param(
        [Parameter(Mandatory)][object[]]$Requests,
        [string]$Version = 'beta'
    )
    $results = @{}
    if (-not $Requests -or $Requests.Count -eq 0) { return $results }

    for ($i = 0; $i -lt $Requests.Count; $i += 20) {
        $slice = $Requests[$i..([Math]::Min($i + 19, $Requests.Count - 1))]
        $payload = @{
            requests = @(foreach ($r in $slice) {
                    $m = 'GET'
                    if ($r.ContainsKey('method') -and $r.method) { $m = $r.method }
                    @{ id = [string]$r.id; method = $m; url = $r.url }
                })
        }
        try {
            $resp = Invoke-IdsGraphRaw -Uri (Resolve-IdsGraphUri -Path '/$batch' -Version $Version) -Method 'POST' -Body $payload
            foreach ($item in @($resp.responses)) {
                $body = $null
                if ($item.PSObject.Properties['body']) { $body = $item.body }
                $results[[string]$item.id] = @{ status = [int]$item.status; body = $body }
            }
        } catch {
            # Fall back to sequential requests for this slice so one bad url cannot lose the batch.
            foreach ($r in $slice) {
                try {
                    $b = Invoke-IdsGraphRaw -Uri (Resolve-IdsGraphUri -Path $r.url -Version $Version) -Method 'GET'
                    $results[[string]$r.id] = @{ status = 200; body = $b }
                } catch {
                    $st = 500
                    if ($_.Exception.PSObject.Properties['StatusCode']) { $st = [int]$_.Exception.StatusCode }
                    $results[[string]$r.id] = @{
                        status = $st; body = $null
                        authenticationFailure = (Test-IdsGraphAuthenticationFailure $_.Exception)
                    }
                }
            }
        }
    }
    return $results
}

function Get-IdsBatchValues {
    <#  Convenience: pull the .value collection out of a batch result entry. #>
    param($Entry)
    if (-not $Entry) { return @() }
    if ($Entry.status -lt 200 -or $Entry.status -ge 300) { return @() }
    $b = $Entry.body
    if (-not $b) { return @() }
    if ($b.PSObject.Properties['value']) { return @($b.value) }
    return @($b)
}

function Test-IdsGraphConnection {
    <#  Cheap probe used by the dashboard to confirm the token really works against Intune. #>
    $out = [ordered]@{ ok = $false; organization = ''; tenantId = ''; intune = $false; message = '' }
    try {
        $org = Invoke-IdsGraph -Path '/organization?$select=id,displayName' -Version 'v1.0' -Tolerant
        if ($org -and $org.value -and @($org.value).Count -gt 0) {
            $out.organization = @($org.value)[0].displayName
            $out.tenantId = @($org.value)[0].id
        }
        $probe = Invoke-IdsGraph -Path '/deviceManagement/configurationPolicies?$top=1' -Tolerant
        if ($null -ne $probe) { $out.intune = $true }
        $out.ok = $true
    } catch {
        $out.message = $_.Exception.Message
    }
    return $out
}
