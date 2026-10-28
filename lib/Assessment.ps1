function Test-IdsWorkActive {
    param([hashtable]$State)
    return [bool]($State.Export.running -or $State.Assessment.running -or $State.Browser.running -or
        ($State.Job -and -not $State.Job.handle.IsCompleted) -or
        ($State.Browser.job -and -not $State.Browser.job.handle.IsCompleted) -or
        ($State.Assessment.job -and -not $State.Assessment.job.handle.IsCompleted))
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
    if (-not $imported) { throw 'Local imported pack directory is not configured.' }
    return Get-IdsBaselinePacks -BundledRoot (Join-Path $Root 'baselines') -ImportedRoot $imported
}

function Assert-IdsAssessmentFields {
    param($Value, [string[]]$Allowed, [string[]]$Required = @())
    if ($Value -isnot [Collections.IDictionary]) { throw 'Assessment input must be an object.' }
    foreach ($key in $Value.Keys) {
        if ($key -cnotin $Allowed) { throw 'Unknown assessment input field.' }
    }
    foreach ($key in $Required) {
        if ($key -cnotin @($Value.Keys)) { throw "Assessment $key is required." }
    }
}

function Resolve-IdsAssessmentOptions {
    param([hashtable]$State, [hashtable]$Options, [string]$Root)
    Assert-IdsAssessmentFields $Options @('packIds', 'context', 'outputPath') @('packIds', 'context', 'outputPath')
    if ($Options.packIds -isnot [array] -or $Options.packIds.Count -lt 1 -or $Options.packIds.Count -gt 64) {
        throw 'Select between 1 and 64 pack identities.'
    }
    $context = $Options.context
    Assert-IdsAssessmentFields $context @('platforms', 'osVersions', 'enrollmentModes') @('platforms')
    $platforms = @('windows11', 'macos', 'iosIpados', 'androidEnterprise')
    if ($context.platforms -isnot [array] -or $context.platforms.Count -lt 1 -or $context.platforms.Count -gt 4) {
        throw 'Select between 1 and 4 platforms.'
    }
    foreach ($platform in $context.platforms) {
        if ($platform -isnot [string] -or $platform -cnotin $platforms) { throw 'Unknown assessment platform.' }
    }
    if (@($context.platforms | Select-Object -Unique).Count -ne $context.platforms.Count) { throw 'Duplicate assessment platform.' }
    $snapshot = @{ platforms = @($context.platforms); osVersions = @{}; enrollmentModes = @{} }
    foreach ($field in 'osVersions', 'enrollmentModes') {
        if ($null -eq $context[$field]) { continue }
        Assert-IdsAssessmentFields $context[$field] $(if ($field -eq 'osVersions') { $platforms } else { @('androidEnterprise', 'iosIpados') })
        foreach ($key in $context[$field].Keys) {
            $value = $context[$field][$key]
            if ($value -isnot [string] -or $value.Length -gt 128) { throw 'Invalid assessment applicability value.' }
            if ($field -eq 'osVersions' -and -not (ConvertTo-IdsRuleOsVersion $value)) { throw 'Invalid assessment OS version.' }
            if ($field -eq 'enrollmentModes') {
                $modes = if ($key -ceq 'iosIpados') { @('personallyOwned', 'corporateOwned') }
                    else { @('workProfile', 'fullyManaged', 'dedicated', 'corporateOwnedWorkProfile') }
                if ($value -cnotin $modes) { throw "Invalid $key enrollment/ownership mode." }
            }
            $snapshot[$field][$key] = $value
        }
    }
    if ($Options.outputPath -isnot [string]) { throw 'Assessment outputPath must be an absolute path.' }
    $output = Get-IdsReportCanonicalRoot $Options.outputPath
    $install = Get-IdsReportCanonicalRoot $Root
    $export = Get-IdsReportCanonicalRoot $State.Config.OutputPath
    Assert-IdsReportDistinctRoots @($output, $install, $export)
    $catalog = Get-IdsAssessmentCatalog $State $Root
    $selected = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($identity in $Options.packIds) {
        if ($identity -isnot [string] -or $identity.Length -gt 512 -or -not $seen.Add($identity)) { throw 'Invalid or duplicate pack identity.' }
        $matches = @($catalog.packs | Where-Object { "$($_.id)@$($_.version)#$($_.sha256)" -ceq $identity })
        if ($matches.Count -eq 0) { throw 'Unknown pack identity or changed SHA-256 hash; reload the catalog.' }
        $pack = $matches[0]
        if ($pack.platform -cnotin $snapshot.platforms) { throw 'Selected pack does not match the platform context.' }
        # These are fresh validated objects, never references retained by the caller
        # or re-read by the worker after admission.
        $selected.Add($pack)
    }
    foreach ($platform in $snapshot.platforms) {
        if ($platform -cnotin @($selected | ForEach-Object platform)) { throw 'Every selected platform requires an applicable pack.' }
    }
    return @{ packs = $selected.ToArray(); context = $snapshot; outputPath = $output; exportRoot = $export }
}

function Start-IdsAssessmentJob {
    param([hashtable]$State, [hashtable]$Options, [string]$Root)
    if (Test-IdsWorkActive $State) { return $false }
    if (-not $State.Auth) { throw 'Not signed in.' }
    if ($State.Browser.running) { return $false }
    Initialize-IdsAssessment $State
    Clear-IdsAssessmentJob $State
    if ($State.Assessment.job) { return $false }
    $resolved = Resolve-IdsAssessmentOptions $State $Options $Root
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
    $assessment.phase = 'Starting'
    $assessment.runId = $runId
    $assessment.running = $true
    # Admission and identity replacement are serialized in the HTTP loop.
    # A worker has its own holder so refresh cannot replace another session.
    $auth = @{}
    foreach ($key in $State.Auth.Keys) { $auth[$key] = $State.Auth[$key] }
    $worker = {
        param($Root, $State, $Options, $Auth, $Epoch, $RunId)
        $ErrorActionPreference = 'Stop'
        $a = $State.Assessment
        try {
            foreach ($module in 'Auth', 'Graph', 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules', 'AssessmentReports') {
                . (Join-Path $Root "lib\$module.ps1")
            }
            if ($Auth.transport -eq 'mggraph') { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop }
            Initialize-IdsGraph -StateHolder @{ Auth = $Auth }
            $a.phase = 'Authenticating'
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
            if ($tenants.Count -ne 1 -or -not $tenants[0].id) { throw 'Cannot establish authenticated tenant.' }
            if ($Auth.tenant_id -and $Auth.tenant_id -ne $tenants[0].id) { throw 'Authenticated tenant does not match the session.' }
            $a.phase = 'Collecting'; $a.percent = 10
            $collection = Get-IdsAssessmentCollection -Packs $Options.packs -Context $Options.context
            if (@($collection.issues | Where-Object { $_.statusCode -eq 401 -or $_.authenticationFailure }).Count) {
                throw 'Assessment authentication failed.'
            }
            $a.phase = 'Normalizing'; $a.percent = 50
            $snapshot = ConvertTo-IdsAssessmentSnapshot -Collection $collection
            $a.phase = 'Evaluating'; $a.percent = 65
            $evaluation = Compare-IdsAssessment -Packs $Options.packs -Snapshot $snapshot -Context $Options.context
            $result = ConvertTo-IdsReportProjection ([pscustomobject]@{
                schemaVersion = 1; runId = $RunId; generatedAt = [datetime]::UtcNow.ToString('o')
                tenant = @{ id = [string]$tenants[0].id; name = [string]$tenants[0].displayName }
                context = $Options.context; packs = @($Options.packs)
                summaries = @($evaluation.summaries); controls = @($evaluation.controls)
                policies = @($snapshot.policies); collectionIssues = @($snapshot.issues); sources = @($snapshot.sources)
            })
            if (-not $State.Auth -or $a.epoch -ne $Epoch -or $a.runId -ne $RunId) { throw 'Assessment session expired.' }
            $a.phase = 'Writing reports'; $a.percent = 85
            $paths = Write-IdsAssessmentReports -Result $result -OutputPath $Options.outputPath -InstallRoot $Root -ExportRoot $Options.exportRoot
            if ($State.Auth -and $a.epoch -eq $Epoch -and $a.runId -eq $RunId) {
                $a.result = $result
                $a.reportPaths = $paths
                $a.partial = [bool](@($result.packs | Where-Object { $_.coverage.inventory -eq 'partial' }).Count -or
                    @($result.controls | Where-Object status -eq 'notAssessed').Count -or $result.collectionIssues.Count -or
                    @($result.sources | Where-Object { -not $_.complete }).Count)
                $a.percent = 100; $a.phase = 'Completed'
            }
        } catch {
            if ($a.epoch -eq $Epoch -and $a.runId -eq $RunId) {
                # Transport/provider exceptions may contain credentials or payloads.
                $a.error = "Assessment failed during $($a.phase). No successful report pair is available."
                $a.result = $null; $a.reportPaths = $null; $a.phase = 'Failed'
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
        [void]$ps.AddScript($worker).AddArgument($Root).AddArgument($State).AddArgument($resolved).AddArgument($auth).AddArgument($epoch).AddArgument($runId)
        $handle = $ps.BeginInvoke()
        $assessment.job = @{ ps = $ps; handle = $handle; runspace = $runspace }
        return $true
    } catch {
        if ($ps) { $ps.Dispose() }
        if ($runspace) { $runspace.Dispose() }
        $assessment.running = $false; $assessment.done = $true; $assessment.phase = 'Failed'
        $assessment.error = 'Unable to start assessment worker.'
        throw [InvalidOperationException]::new($assessment.error)
    }
}

function Clear-IdsAssessmentJob {
    param([hashtable]$State)
    $job = $State.Assessment.job
    if (-not $job -or -not $job.handle.IsCompleted) { return }
    try { [void]$job.ps.EndInvoke($job.handle) } catch {
        $State.Assessment.error = 'Assessment worker terminated unexpectedly.'
        $State.Assessment.result = $null; $State.Assessment.reportPaths = $null
    } finally {
        $job.ps.Dispose(); $job.runspace.Dispose()
        $State.Assessment.job = $null
        if ($State.Assessment.running) {
            $State.Assessment.error = 'Assessment worker terminated unexpectedly.'
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
            $State.Assessment.done = $true; $State.Assessment.error = 'Assessment cancelled.'
            $State.Assessment.phase = 'Cancelled'; $State.Assessment.result = $null; $State.Assessment.reportPaths = $null
        }
    }
}

function Reset-IdsAssessment {
    param([hashtable]$State)
    if (Test-IdsWorkActive $State) { throw 'An export or assessment is still running.' }
    Initialize-IdsAssessment $State
    Clear-IdsAssessmentJob $State
    $a = $State.Assessment
    $a.epoch = [long]$a.epoch + 1
    $a.resultEpoch = $null; $a.runId = $null; $a.result = $null
    $a.reportPaths = $null; $a.error = $null; $a.percent = 0; $a.phase = ''
    $a.running = $false; $a.done = $false; $a.partial = $false
    $State.Pending = $null
}
