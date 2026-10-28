<#
    Http.ps1 — minimal HTTP plumbing for the local dashboard.

    Binds to http://localhost:<port>/ which Windows permits without elevation. Nothing is
    exposed off-box: the listener is loopback only and every response carries no-store.
#>

function New-IdsContextWaiter {
    <#  Wraps HttpListener in a non-blocking accept loop.

        HttpListener.GetContext() blocks inside native code, and while it does PowerShell
        cannot act on Ctrl+C — the console appears frozen until a request happens to arrive.
        A single pending BeginGetContext, polled with a short timeout, hands control back to
        the caller regularly so cancellation is honoured. The pending operation is kept
        across polls rather than restarted, so nothing accumulates. #>
    param([System.Net.HttpListener]$Listener)
    return [pscustomobject]@{ Listener = $Listener; Pending = $null }
}

function Wait-IdsHttpContext {
    <#  Returns a context, or $null when nothing arrived within the timeout. #>
    param($Waiter, [int]$TimeoutMs = 250)

    $listener = $Waiter.Listener
    if (-not $listener.IsListening) { return $null }

    if (-not $Waiter.Pending) {
        try { $Waiter.Pending = $listener.BeginGetContext($null, $null) }
        catch { return $null }
    }
    if (-not $Waiter.Pending.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $null }

    $async = $Waiter.Pending
    $Waiter.Pending = $null
    try { return $listener.EndGetContext($async) } catch { return $null }
}

function Stop-IdsHttpListener {
    param([System.Net.HttpListener]$Listener)
    if (-not $Listener) { return }
    try { if ($Listener.IsListening) { $Listener.Stop() } } catch { }
    try { $Listener.Close() } catch { }
}

function New-IdsHttpListener {
    param([int]$Port)
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    return $listener
}

function Get-IdsQuery {
    <#  Parses a query string into a case-insensitive hashtable. #>
    param([string]$Query)
    $out = @{}
    if (-not $Query) { return $out }
    $q = $Query.TrimStart('?')
    if (-not $q) { return $out }
    foreach ($pair in $q.Split('&')) {
        if (-not $pair) { continue }
        $idx = $pair.IndexOf('=')
        if ($idx -lt 0) { $out[[uri]::UnescapeDataString($pair)] = '' ; continue }
        $k = [uri]::UnescapeDataString($pair.Substring(0, $idx))
        $v = [uri]::UnescapeDataString($pair.Substring($idx + 1).Replace('+', ' '))
        $out[$k] = $v
    }
    return $out
}

function Read-IdsRequestBody {
    param($Request)
    if (-not $Request.HasEntityBody) { return $null }
    $reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-IdsRequestJson {
    param($Request)
    $body = Read-IdsRequestBody -Request $Request
    if (-not $body) { return @{} }
    try { return ($body | ConvertFrom-Json) } catch { return @{} }
}

function Send-IdsResponse {
    param($Response, [byte[]]$Bytes, [string]$ContentType = 'text/plain; charset=utf-8', [int]$Status = 200)
    try {
        $Response.StatusCode = $Status
        $Response.ContentType = $ContentType
        $Response.Headers['Cache-Control'] = 'no-store'
        $Response.ContentLength64 = $Bytes.Length
        $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    } catch {
        # Client disconnected mid-write; nothing useful to do.
    } finally {
        try { $Response.OutputStream.Close() } catch { }
    }
}

function Send-IdsText {
    param($Response, [string]$Text, [string]$ContentType = 'text/plain; charset=utf-8', [int]$Status = 200)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    Send-IdsResponse -Response $Response -Bytes $bytes -ContentType $ContentType -Status $Status
}

function Send-IdsJson {
    param($Response, $Object, [int]$Status = 200)
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    if ($null -eq $json) { $json = 'null' }
    Send-IdsText -Response $Response -Text $json -ContentType 'application/json; charset=utf-8' -Status $Status
}

function Send-IdsStaticFile {
    param($Response, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Send-IdsText -Response $Response -Text 'Not found' -Status 404
        return
    }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $type = 'application/octet-stream'
    switch ($ext) {
        '.html' { $type = 'text/html; charset=utf-8' }
        '.js'   { $type = 'application/javascript; charset=utf-8' }
        '.css'  { $type = 'text/css; charset=utf-8' }
        '.svg'  { $type = 'image/svg+xml' }
        '.json' { $type = 'application/json; charset=utf-8' }
    }
    Send-IdsResponse -Response $Response -Bytes ([IO.File]::ReadAllBytes($Path)) -ContentType $type
}

function Send-IdsRedirect {
    param($Response, [string]$Location)
    try {
        $Response.StatusCode = 302
        $Response.Headers['Location'] = $Location
        $Response.Headers['Cache-Control'] = 'no-store'
        $Response.ContentLength64 = 0
    } catch { } finally {
        try { $Response.OutputStream.Close() } catch { }
    }
}

function Open-IdsBrowser {
    param([string]$Url)
    try { Start-Process $Url | Out-Null } catch {
        try { Start-Process 'cmd.exe' -ArgumentList '/c', 'start', '""', $Url -WindowStyle Hidden | Out-Null } catch { }
    }
}
