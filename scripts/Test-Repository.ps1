[CmdletBinding()]
param(
    [string]$Before,
    [string]$After,
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RepositoryPolicy.ps1')

if (($PSBoundParameters.ContainsKey('Before')) -ne ($PSBoundParameters.ContainsKey('After'))) {
    Write-Host 'FAIL: supply both -Before and -After to check a VERSION change.' -ForegroundColor Red
    exit 2
}

$violations = [System.Collections.Generic.List[string]]::new()
$violations.AddRange([string[]]@(Test-IdsAgentInstructions -Root $Root))
$violations.AddRange([string[]]@(Test-IdsVersionFormat -Root $Root))

$eventName = $env:IDS_EVENT_NAME
if ($eventName -ceq 'pull_request') {
    $requiredContext = @(
        $env:IDS_PR_BASE
        $env:IDS_PR_HEAD
        $env:IDS_REPOSITORY
        $env:IDS_PR_HEAD_REPOSITORY
    )
    if (@($requiredContext | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        $violations.Add('Pull request policy context is incomplete. Supply base/head refs and both repository names through IDS_PR_* environment variables.')
    } else {
        $sameRepository = [string]::Equals(
            $env:IDS_REPOSITORY,
            $env:IDS_PR_HEAD_REPOSITORY,
            [System.StringComparison]::OrdinalIgnoreCase
        )
        $violations.AddRange([string[]]@(
            Test-IdsPullRequestTarget -Base $env:IDS_PR_BASE -Head $env:IDS_PR_HEAD -SameRepository $sameRepository
        ))
    }

    $beforeSha = if ($PSBoundParameters.ContainsKey('Before')) { $Before } else { $env:IDS_PR_BASE_SHA }
    $afterSha = if ($PSBoundParameters.ContainsKey('After')) { $After } else { $env:IDS_PR_HEAD_SHA }
    if ([string]::IsNullOrWhiteSpace($beforeSha) -or [string]::IsNullOrWhiteSpace($afterSha)) {
        $violations.Add('Pull request VERSION policy requires base and head commit SHAs through IDS_PR_BASE_SHA and IDS_PR_HEAD_SHA.')
    } else {
        $violations.AddRange([string[]]@(
            Test-IdsVersionChange -Root $Root -Before $beforeSha -After $afterSha
        ))
    }
} elseif ($eventName -ceq 'push') {
    Write-Host 'Pull request target policy: not applicable to push events.' -ForegroundColor DarkGray
} elseif ($PSBoundParameters.ContainsKey('Before')) {
    $violations.AddRange([string[]]@(Test-IdsVersionChange -Root $Root -Before $Before -After $After))
} else {
    Write-Host 'Pull request target policy: not applicable without pull request event context.' -ForegroundColor DarkGray
}

if ($violations.Count -gt 0) {
    foreach ($violation in $violations) {
        Write-Host "FAIL: $violation" -ForegroundColor Red
    }
    exit 1
}

Write-Host 'Repository guidance and local policy checks passed.' -ForegroundColor Green
exit 0
