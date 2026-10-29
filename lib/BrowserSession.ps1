. (Join-Path $PSScriptRoot 'Localization.ps1')

<#
    BrowserSession.ps1 — reuse the administrator's existing Intune admin center session.

    WHY THIS EXISTS
    ---------------
    Every DeviceManagement*.Read.All scope is admin-only: a user can never self-consent to
    them. Granting consent needs Global Administrator, Privileged Role Administrator, Cloud
    Application Administrator or Application Administrator. An account holding only the
    *Intune Administrator* role therefore cannot approve the consent prompt, even though that
    same account can read every one of those objects in the Intune admin center.

    This module closes that gap. The Intune admin center is itself already consented in every
    tenant, so we drive a real browser to it, let the administrator sign in exactly as they
    normally do, and observe the access token the portal itself obtains for Microsoft Graph.
    No consent prompt, no app registration, no new grant in the directory.

    HOW
    ---
    Edge (or Chrome) is launched with --remote-debugging-port against an isolated profile.
    We attach over the Chrome DevTools Protocol, enable the Network domain, and read the
    Authorization header from the portal's own calls to graph.microsoft.com.

    LIMITS — be honest about these
    ------------------------------
    * The captured token is short-lived (typically ~60-75 minutes) and cannot be refreshed
      here, because the refresh token stays inside the portal. Very large tenants may need a
      re-capture; the exporter reports a clear error if the token expires mid-run.
    * The token's scopes are whatever the portal requested, not what we asked for. We verify
      the audience is Microsoft Graph and report the scopes actually present.
    * This depends on the admin center's current implementation and is not a supported
      Microsoft integration pattern. It is ideal for an assessment or a one-off handover; for
      a recurring pipeline, a one-time admin consent is the sturdier choice.
#>

function Find-IdsBrowser {
    <#  Prefers Edge, falls back to Chrome. #>
    param([string]$Preferred)
    $candidates = @()
    if ($Preferred) { $candidates += $Preferred }
    $candidates += @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

function Get-IdsFreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start()
    $port = $l.LocalEndpoint.Port
    $l.Stop()
    return $port
}

function Get-IdsBrowserProfilePath {
    <#  A persistent profile means the administrator signs in once, not on every run.
        It lives under LOCALAPPDATA, deliberately outside OneDrive, so nothing syncs. #>
    param([switch]$Ephemeral)
    if ($Ephemeral) {
        return (Join-Path $env:TEMP ('ids-browser-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)))
    }
    $p = Join-Path $env:LOCALAPPDATA 'IntuneDocsStudio\browser-profile'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    return $p
}

function Clear-IdsBrowserProfile {
    $p = Join-Path $env:LOCALAPPDATA 'IntuneDocsStudio\browser-profile'
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
}

function Connect-IdsCdpSocket {
    param([string]$WebSocketUrl, [int]$TimeoutSeconds = 15)
    $ws = New-Object Net.WebSockets.ClientWebSocket
    $cts = New-Object Threading.CancellationTokenSource([TimeSpan]::FromSeconds($TimeoutSeconds))
    # [void] matters: awaiting a non-generic Task emits a VoidTaskResult object in PowerShell 7,
    # which would otherwise be returned alongside the socket.
    [void]$ws.ConnectAsync([Uri]$WebSocketUrl, $cts.Token).GetAwaiter().GetResult()
    return $ws
}

function Send-IdsCdpCommand {
    param(
        [Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params,
        [string]$SessionId
    )
    $msg = @{ id = $Id; method = $Method }
    if ($Params) { $msg['params'] = $Params }
    # With flattened auto-attach, a sessionId routes the command to that specific target.
    if ($SessionId) { $msg['sessionId'] = $SessionId }
    $json = $msg | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object ArraySegment[byte] (, $bytes)
    $cts = New-Object Threading.CancellationTokenSource([TimeSpan]::FromSeconds(10))
    [void]$Socket.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
}

function Receive-IdsCdpMessage {
    <#  Reads one complete CDP frame. Returns $null on timeout so the caller can keep polling
        and stay responsive to cancellation. #>
    param([Net.WebSockets.ClientWebSocket]$Socket, [int]$TimeoutSeconds = 2)
    $buffer = New-Object byte[] 65536
    $sb = New-Object Text.StringBuilder
    $cts = New-Object Threading.CancellationTokenSource([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        do {
            $seg = New-Object ArraySegment[byte] (, $buffer)
            $result = $Socket.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
            if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { return $null }
            [void]$sb.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
        } while (-not $result.EndOfMessage)
    } catch { return $null }
    $text = $sb.ToString()
    if (-not $text) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Test-IdsGraphToken {
    <#  Confirms a captured bearer really is a Microsoft Graph token for a signed-in user. #>
    param([string]$Token)
    $claims = ConvertFrom-IdsJwt $Token
    if (-not $claims) { return $null }
    $aud = [string]$claims.aud
    if ($aud -notmatch 'graph\.microsoft\.com' -and $aud -ne '00000003-0000-0000-c000-000000000000') { return $null }
    return $claims
}

function Test-IdsTokenAgainstIntune {
    <#  The decisive test. Rather than guessing from the scp claim — which varies with how
        the portal requested the token — simply try the read we actually need. A 200 means
        the token works, whatever its scopes happen to say. #>
    param([string]$Token)
    try {
        $r = Invoke-WebRequest -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$top=1' `
            -Headers @{ Authorization = "Bearer $Token" } -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        return ([int]$r.StatusCode -ge 200 -and [int]$r.StatusCode -lt 300)
    } catch {
        return $false
    }
}

function Test-IdsBrowserAlive {
    <#  Authoritative liveness check. The PID returned by Start-Process is unreliable:
        Chromium frequently relaunches itself, so the original process can exit while the
        browser is very much alive — and conversely it can linger after the window is gone.
        The DevTools endpoint is the honest signal. #>
    param([int]$Port, [int]$ProcessId)
    try {
        $null = Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 3
        return $true
    } catch { }
    if ($ProcessId -and (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
    return $false
}

function Close-IdsBrowser {
    <#  Chromium keeps cookies and token cache in memory and flushes them on a clean exit.
        Force-killing the process therefore throws the sign-in away — which is exactly why
        the saved session used to be forgotten between runs. Ask the browser to close itself
        over CDP, wait for it, and only resort to force as a genuine last measure. #>
    param(
        [Net.WebSockets.ClientWebSocket]$Socket,
        [int]$ProcessId,
        [int]$TimeoutSeconds = 20
    )
    $closedCleanly = $false
    if ($Socket -and $Socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
        try {
            Send-IdsCdpCommand -Socket $Socket -Id 999999 -Method 'Browser.close'
            $closedCleanly = $true
        } catch { }
    }
    if ($ProcessId) {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 250
        }
        if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
            $closedCleanly = $false
            Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    # Give Chromium a moment to finish writing Cookies / Preferences before anyone reads them.
    Start-Sleep -Milliseconds 1200
    return $closedCleanly
}

function Initialize-IdsProfilePreferences {
    <#  Kept as a no-op hook: Edge rewrites Default\Preferences wholesale on startup, so
        seeding it there does not survive. Session-cookie persistence is achieved with the
        --restore-last-session switch instead (see the launch arguments below). #>
    param([string]$ProfileDir)
}

function Get-IdsCdpContexts {
    <#  Enumerates the JavaScript execution contexts of a target.

        Runtime.evaluate without a contextId uses the target's *default* context, which is
        frequently still the initial about:blank rather than the loaded page — storage then
        reads as empty and the caller silently finds nothing. Enabling Runtime replays
        executionContextCreated for every existing context, so we can pick the right one. #>
    param([Net.WebSockets.ClientWebSocket]$Socket, [int]$TimeoutSeconds = 6)
    $contexts = @()
    Send-IdsCdpCommand -Socket $Socket -Id 6900 -Method 'Runtime.enable'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $m = Receive-IdsCdpMessage -Socket $Socket -TimeoutSeconds 1
        if ($null -eq $m) {
            # Nothing more queued; the replay is done.
            if ($contexts.Count -gt 0) { break } else { continue }
        }
        if ($m.method -eq 'Runtime.executionContextCreated') {
            $c = $m.params.context
            if ($c) {
                $contexts += [pscustomobject]@{
                    Id     = $c.id
                    Origin = [string]$c.origin
                    Name   = [string]$c.name
                }
            }
        }
        if ($m.id -eq 6900 -and $contexts.Count -gt 0) { break }
    }
    return $contexts
}

function Invoke-IdsCdpEvaluate {
    <#  Runs JavaScript in a page target and returns the value.

        When ContextId is supplied the expression runs in that specific execution context;
        otherwise it uses the target default, which may not be the loaded page. #>
    param(
        [Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Expression,
        [string]$SessionId,
        $ContextId,
        [int]$TimeoutSeconds = 15
    )
    $p = @{ expression = $Expression; returnByValue = $true; awaitPromise = $true }
    if ($null -ne $ContextId) { $p['contextId'] = $ContextId }
    Send-IdsCdpCommand -Socket $Socket -Id $Id -Method 'Runtime.evaluate' -SessionId $SessionId -Params $p
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $m = Receive-IdsCdpMessage -Socket $Socket -TimeoutSeconds 2
        if ($null -eq $m) { continue }
        if ($m.id -eq $Id) {
            if ($m.result -and $m.result.result) { return $m.result.result.value }
            return $null
        }
    }
    return $null
}

# JavaScript that harvests every JWT the page has cached, wherever it lives.
#
# Deliberately does not assume MSAL key names: portal versions and MSAL releases differ, and
# a tester's tenant may not match what we saw locally. Instead every storage value is scanned
# for anything JWT-shaped, and the audience check in PowerShell decides what is useful.
$script:IdsHarvestJs = @'
(function(){
  var out=[];
  function addJwt(s){
    if(!s || typeof s !== 'string') return;
    var m = s.match(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*/g);
    if(!m) return;
    for(var i=0;i<m.length;i++){ if(out.indexOf(m[i])<0) out.push(m[i]); }
  }
  function walk(v, depth){
    if(depth > 4 || v === null || v === undefined) return;
    if(typeof v === 'string'){ addJwt(v); return; }
    if(typeof v === 'object'){
      for(var k in v){
        try{ walk(v[k], depth+1); }catch(e){}
      }
    }
  }
  function grab(store){
    try{
      for(var i=0;i<store.length;i++){
        var k=store.key(i);
        var v=store.getItem(k);
        if(!v) continue;
        if(v.indexOf('eyJ') < 0) continue;   // cheap pre-filter
        addJwt(v);
        try{ walk(JSON.parse(v), 0); }catch(e){}
      }
    }catch(e){}
  }
  try{ grab(window.sessionStorage); }catch(e){}
  try{ grab(window.localStorage); }catch(e){}
  return JSON.stringify(out);
})()
'@

function Get-IdsPortalTokens {
    <#  Reads every JWT cached by the portal and returns them.

        Scans page AND iframe targets: the Intune portal renders each blade inside a
        reactblade.portal.azure.net iframe, which is a separate origin with its own storage.
        Looking only at the top-level page misses whatever lives there.

        Optionally reports what it saw, so a remote tester's failure can be diagnosed. #>
    param([int]$Port, [ref]$Diagnostics)
    $tokens = @()
    $seen = [ordered]@{ targets = 0; scanned = 0; origins = @() }
    try {
        $list = Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 5
    } catch {
        if ($Diagnostics) { $Diagnostics.Value = $seen }
        return $tokens
    }

    $candidates = @($list | Where-Object {
            $_.webSocketDebuggerUrl -and
            ($_.type -eq 'page' -or $_.type -eq 'iframe' -or $_.type -eq 'other') -and
            $_.url -like 'https://*'
        })
    $seen.targets = $candidates.Count

    foreach ($p in $candidates) {
        # NB: not $host — that is an automatic PowerShell variable (the host UI object).
        $originHost = ''
        try { $originHost = ([Uri]$p.url).Host } catch { continue }
        # Only Microsoft-operated origins hold portal tokens; skip anything else outright.
        if ($originHost -notlike '*.microsoft.com' -and $originHost -notlike '*.azure.net' -and
            $originHost -notlike '*.azure.com' -and $originHost -notlike '*.windows.net') { continue }

        $sock = $null
        try {
            $sock = Connect-IdsCdpSocket -WebSocketUrl $p.webSocketDebuggerUrl -TimeoutSeconds 6

            # Evaluate in every real execution context of this target, not just the default
            # one: the default is often still about:blank, whose storage is empty.
            $contexts = @(Get-IdsCdpContexts -Socket $sock)
            $useful = @($contexts | Where-Object { $_.Origin -like 'https://*' })
            $evalIn = @()
            foreach ($c in $useful) { $evalIn += $c.Id }
            if ($evalIn.Count -eq 0) { $evalIn += $null }   # fall back to the default context

            $n = 7000
            foreach ($cid in $evalIn) {
                $n++
                $raw = Invoke-IdsCdpEvaluate -Socket $sock -Id $n -Expression $script:IdsHarvestJs -ContextId $cid -TimeoutSeconds 10
                if (-not $raw) { continue }
                foreach ($t in @($raw | ConvertFrom-Json)) {
                    if ($t -and $tokens -notcontains $t) { $tokens += $t }
                }
            }
            $seen.scanned++
            if ($seen.origins -notcontains $originHost) { $seen.origins += $originHost }
        } catch {
        } finally {
            if ($sock) { try { $sock.Dispose() } catch { } }
        }
    }
    if ($Diagnostics) { $Diagnostics.Value = $seen }
    return $tokens
}

function Invoke-IdsPortalNudge {
    <#  Navigates the portal to a blade that forces it to acquire an Intune-scoped Graph
        token. When single sign-on drops the user straight onto a landing page, the portal
        may never request that token on its own, and the capture would wait forever. #>
    param([int]$Port, [string]$Tenant)
    $tenantSegment = ''
    if ($Tenant -and $Tenant -ne 'organizations' -and $Tenant -ne 'common') { $tenantSegment = "$Tenant/" }
    $url = "https://intune.microsoft.com/$tenantSegment#view/Microsoft_Intune_DeviceSettings/DevicesMenu/~/configuration"
    try {
        $list = Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 5
    } catch { return $false }
    $page = @($list | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl -and $_.url -like '*intune.microsoft.com*' }) | Select-Object -First 1
    if (-not $page) { return $false }
    $sock = $null
    try {
        $sock = Connect-IdsCdpSocket -WebSocketUrl $page.webSocketDebuggerUrl -TimeoutSeconds 6
        Send-IdsCdpCommand -Socket $sock -Id 7100 -Method 'Page.enable'
        Send-IdsCdpCommand -Socket $sock -Id 7101 -Method 'Page.navigate' -Params @{ url = $url }
        return $true
    } catch { return $false } finally {
        if ($sock) { try { $sock.Dispose() } catch { } }
    }
}

function Select-IdsUsableToken {
    <#  Picks the first cached token that is a Microsoft Graph token for the expected tenant
        AND actually reads Intune configuration. The portal caches several tokens for
        different audiences and scopes; only one of them is the one we need. #>
    param([string[]]$Tokens, [string]$WantTenant, [hashtable]$Tried, [ref]$WrongTenant)
    foreach ($t in @($Tokens)) {
        if (-not $t) { continue }
        $fp = $t.Substring([Math]::Max(0, $t.Length - 24))
        if ($Tried.ContainsKey($fp)) { continue }
        $Tried[$fp] = $true

        $claims = Test-IdsGraphToken -Token $t
        if (-not $claims) { continue }

        $tid = ''
        if ($claims.PSObject.Properties['tid']) { $tid = [string]$claims.tid }
        if ($WantTenant -and $tid -and $tid -ne $WantTenant) { $WrongTenant.Value = $true; continue }

        if (-not (Test-IdsTokenAgainstIntune -Token $t)) { continue }

        $scopes = @()
        if ($claims.PSObject.Properties['scp'] -and $claims.scp) { $scopes = @($claims.scp -split ' ') }
        return @{ token = $t; claims = $claims; scopes = $scopes }
    }
    return $null
}

function Get-IdsTokenFromBrowser {
    <#  .SYNOPSIS
            Launches a browser to the Intune admin center and captures the Microsoft Graph
            access token that the portal acquires for the signed-in administrator.

        .PARAMETER ForceAccountPicker
            Signs the browser session out first and opens an InPrivate window, so Windows
            single sign-on cannot silently reuse the machine's everyday account. Needed when
            the operator's admin account differs from the account the device is joined with.

        .PARAMETER StatusCallback
            Optional scriptblock invoked with progress strings, so the dashboard can narrate.
    #>
    param(
        [string]$Tenant,
        [int]$TimeoutSeconds = 600,
        [string]$BrowserPath,
        [scriptblock]$StatusCallback,
        [switch]$Ephemeral,
        [switch]$ForceAccountPicker
    )

    function Report { param([string]$m) if ($StatusCallback) { & $StatusCallback $m } else { Write-Host "  $m" } }

    $exe = Find-IdsBrowser -Preferred $BrowserPath
    if (-not $exe) { throw (Get-IdsText -Key 'text.neither_microsoft_edge_nor_google_chrome_could_be_found_install_one_or_use_a_different_sign_in_metho') }

    $port = Get-IdsFreePort
    $profileDir = Get-IdsBrowserProfilePath -Ephemeral:($Ephemeral -or $ForceAccountPicker)
    Initialize-IdsProfilePreferences -ProfileDir $profileDir

    # Land directly on a blade that forces the portal to load Intune configuration data.
    $tenantSegment = ''
    if ($Tenant -and $Tenant -ne 'organizations' -and $Tenant -ne 'common') { $tenantSegment = "$Tenant/" }
    $portalUrl = "https://intune.microsoft.com/$tenantSegment#view/Microsoft_Intune_DeviceSettings/DevicesMenu/~/configuration"

    $startUrl = $portalUrl
    if ($ForceAccountPicker) {
        # Signing the session out first makes Entra ID present the account picker instead of
        # silently reusing whichever account the device is joined with.
        $startUrl = 'https://login.microsoftonline.com/common/oauth2/v2.0/logout?post_logout_redirect_uri=' +
        [uri]::EscapeDataString($portalUrl)
    }

    $browserArgs = @(
        "--remote-debugging-port=$port"
        "--user-data-dir=$profileDir"
        '--no-first-run'
        '--no-default-browser-check'
        # Windows SSO would silently sign the window in as the machine's work account, which
        # is usually NOT the tenant being documented. Force an explicit account choice.
        '--disable-features=msImplicitSignIn,msSingleSignOnOSForPrimaryAccountIsShared,msEdgeWelcomePage,msEdgeIdentityAutoSignIn'
        '--disable-sync'
        '--no-service-autorun'
    )
    if ($ForceAccountPicker) {
        # InPrivate suppresses the browser's own account carry-over as well. Security keys,
        # passkeys and Windows Hello all keep working: WebAuthn is not profile-bound.
        $browserArgs += '--inprivate'
        $browserArgs += '--incognito'
    } else {
        # Session restore lets the sign-in survive when "Stay signed in?" is declined.
        $browserArgs += '--restore-last-session'
    }
    $browserArgs += '--new-window'
    $browserArgs += $startUrl

    Report (Get-IdsText -Key 'text.starting_a_browser_window_for_the_intune_admin_center')
    $proc = Start-Process -FilePath $exe -ArgumentList $browserArgs -PassThru
    $browserPid = $proc.Id

    $socket = $null
    try {
        # Wait for the DevTools endpoint. We no longer hold a browser-level socket for the
        # whole session: tokens are read straight from the portal's MSAL cache, which is far
        # more reliable than trying to observe traffic from cross-origin blade iframes.
        $ready = $false
        $deadline = (Get-Date).AddSeconds(40)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            try {
                $v = Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 5
                if ($v.webSocketDebuggerUrl) { $ready = $true; break }
            } catch { }
        }
        if (-not $ready) { throw (Get-IdsText -Key 'text.could_not_attach_to_the_browser_close_any_other_debugging_session_and_try_again') }

        Report (Get-IdsText -Key 'text.sign_in_to_the_intune_admin_center_in_the_browser_window_that_just_opened')
        Report (Get-IdsText -Key 'text.this_is_your_normal_portal_sign_in_no_consent_prompt_no_app_registration')

        $captured = $null
        $wrongTenant = $false
        $sawAnyToken = $false
        $graphSeen = 0
        $nudged = $false
        $diag = $null
        $wantTenant = ''
        if ($Tenant -and $Tenant -ne 'organizations' -and $Tenant -ne 'common') { $wantTenant = $Tenant }
        $tried = @{}
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $started = Get-Date
        $lastNote = Get-Date

        while ((Get-Date) -lt $deadline -and -not $captured) {
            if (-not (Test-IdsBrowserAlive -Port $port -ProcessId $browserPid)) {
                throw (Get-IdsText -Key 'text.the_browser_window_was_closed_before_sign_in_finished_click_sign_in_via_the_intune_portal_again_and_')
            }

            $d = $null
            $tokens = @(Get-IdsPortalTokens -Port $port -Diagnostics ([ref]$d))
            $diag = $d
            if ($tokens.Count -gt 0) { $sawAnyToken = $true }

            # Count Graph tokens separately: "tokens exist but none are for Graph" and
            # "no tokens at all" are different problems and need different advice.
            foreach ($t in $tokens) {
                if (Test-IdsGraphToken -Token $t) { $graphSeen++ ; break }
            }

            $wt = $false
            $hit = Select-IdsUsableToken -Tokens $tokens -WantTenant $wantTenant -Tried $tried -WrongTenant ([ref]$wt)
            if ($wt) { $wrongTenant = $true }
            if ($hit) { $captured = $hit; break }

            # Single sign-on can drop the user on a landing page that never needs an
            # Intune-scoped token. Push the portal to a blade that does.
            $elapsed = ((Get-Date) - $started).TotalSeconds
            if (-not $nudged -and $sawAnyToken -and $elapsed -gt 15) {
                $nudged = $true
                Report (Get-IdsText -Key 'text.opening_devices_configuration_profiles_to_prompt_the_portal_for_an_intune_token')
                [void](Invoke-IdsPortalNudge -Port $port -Tenant $Tenant)
            }

            if (((Get-Date) - $lastNote).TotalSeconds -gt 15) {
                if ($wrongTenant) {
                    Report (Get-IdsText -Key 'text.signed_in_with_an_account_from_a_different_tenant_use_sign_in_with_a_different_account_in_the_portal')
                } elseif ($graphSeen -gt 0) {
                    Report (Get-IdsText -Key 'text.signed_in_checking_the_portal_s_tokens_for_intune_access')
                } elseif ($sawAnyToken) {
                    Report (Get-IdsText -Key 'text.signed_in_waiting_for_the_portal_to_acquire_a_microsoft_graph_token_open_devices_configuration_profi')
                } else {
                    $where = ''
                    if ($diag -and $diag.origins.Count -gt 0) { $where = (Get-IdsText -Key 'text.watching_arg0' -Arguments @{ arg0 = (@($diag.origins) -join ', ') }) }
                    Report (Get-IdsText -Key 'text.waiting_for_you_to_complete_sign_in_arg0' -Arguments @{ arg0 = ($where) })
                }
                $lastNote = Get-Date
            }
            Start-Sleep -Seconds 2
        }

        if (-not $captured) {
            if ($wrongTenant) {
                throw (Get-IdsText -Key 'text.the_browser_signed_in_with_an_account_from_a_different_tenant_tick_force_account_picker_and_try_agai')
            }
            if ($graphSeen -gt 0) {
                $who = ''
                foreach ($t in $tokens) {
                    $c = ConvertFrom-IdsJwt $t
                    if ($c -and $c.PSObject.Properties['upn'] -and $c.upn) { $who = [string]$c.upn; break }
                }
                $whoText = ''
                if ($who) { $whoText = (Get-IdsText -Key 'text.the_signed_in_account_is_arg0' -Arguments @{ arg0 = ($who) }) }
                throw ((Get-IdsText -Key 'text.signed_in_but_none_of_the_portal_s_microsoft_graph_tokens_could_read_intune_configuration_arg0' -Arguments @{ arg0 = ($whoText) }) +
                    (Get-IdsText -Key 'text.if_that_is_not_your_admin_account_tick_force_account_picker_and_sign_in_again_otherwise_that_account'))
            }
            if ($sawAnyToken) {
                $origins = ''
                if ($diag -and $diag.origins.Count -gt 0) { $origins = (Get-IdsText -Key 'text.origins_scanned') + (@($diag.origins) -join ', ') + '.' }
                throw ((Get-IdsText -Key 'text.signed_in_but_the_portal_never_acquired_a_microsoft_graph_token_open_devices_configuration_profiles_' -Arguments @{ arg0 = ($origins) }))
            }
            $waited = [int]((Get-Date) - $started).TotalSeconds
            $extra = ''
            if ($diag) { $extra = (Get-IdsText -Key 'text.scanned_arg0_of_arg1_browser_targets' -Arguments @{ arg0 = ($diag.scanned); arg1 = ($diag.targets) }) }
            throw (Get-IdsText -Key 'text.no_sign_in_was_detected_after_arg0_seconds_make_sure_you_completed_the_sign_in_in_the_browser_window' -Arguments @{ arg0 = ($waited); arg1 = ($extra) })
        }

        $claims = $captured.claims
        $account = ''
        foreach ($c in @('upn', 'preferred_username', 'unique_name')) {
            if ($claims.PSObject.Properties[$c] -and $claims.$c) { $account = $claims.$c; break }
        }
        $expires = (Get-Date).ToUniversalTime().AddMinutes(50)
        if ($claims.PSObject.Properties['exp']) {
            try { $expires = [DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.exp).UtcDateTime.AddMinutes(-2) } catch { }
        }
        $tid = ''
        if ($claims.PSObject.Properties['tid']) { $tid = [string]$claims.tid }

        Report (Get-IdsText -Key 'text.captured_a_microsoft_graph_token_for_arg0' -Arguments @{ arg0 = ($account) })
        $mins = [int]([Math]::Max(0, ($expires - (Get-Date).ToUniversalTime()).TotalMinutes))
        Report (Get-IdsText -Key 'text.valid_for_about_arg0_more_minutes_it_cannot_be_renewed_automatically' -Arguments @{ arg0 = ($mins) })

        return @{
            access_token  = $captured.token
            refresh_token = $null
            expires_at    = $expires
            client_id     = $(if ($claims.PSObject.Properties['appid']) { [string]$claims.appid } else { '' })
            tenant        = $tid
            tenant_id     = $tid
            account       = $account
            method        = 'browser'
            granted       = $captured.scopes
            transport     = 'token'
            ephemeral     = $true
        }
    } finally {
        # Close cleanly so Chromium flushes cookies to disk: this is what makes the sign-in
        # survive to the next run. We no longer hold a long-lived socket, so open one purely
        # to deliver Browser.close.
        $closeSocket = $null
        try {
            $v = Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 3
            if ($v.webSocketDebuggerUrl) { $closeSocket = Connect-IdsCdpSocket -WebSocketUrl $v.webSocketDebuggerUrl -TimeoutSeconds 5 }
        } catch { }
        [void](Close-IdsBrowser -Socket $closeSocket -ProcessId $browserPid)
        if ($closeSocket) { try { $closeSocket.Dispose() } catch { } }
        if ($socket) { try { $socket.Dispose() } catch { } }
        # A persistent profile is kept on purpose so the next run does not need a fresh sign-in.
        if ($Ephemeral -and (Test-Path -LiteralPath $profileDir)) {
            Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
