[CmdletBinding()]
param(
    [string]$Before,
    [string]$PromotionSha,
    [string]$RecoveryVersionCommit,
    [switch]$PlanOnly,
    [switch]$PrepareOnly,
    [switch]$PublishPrepared,
    [switch]$PrepareArtifact,
    [string]$ArtifactDirectory,
    [string]$ArtifactRunId
)

. (Join-Path $PSScriptRoot 'ReleasePolicy.ps1')

function Invoke-IdsGit {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $Root @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { "$_" }) -join "`n"
        throw "Git command failed ($($Arguments -join ' ')): $detail"
    }
    return ($output | ForEach-Object { "$_" }) -join "`n"
}

function Invoke-IdsGitHub {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & gh @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { "$_" }) -join "`n"
        throw "GitHub CLI failed ($($Arguments -join ' ')): $detail"
    }
    return ($output | ForEach-Object { "$_" }) -join "`n"
}

function Assert-IdsStableCredential {
    if ([string]::IsNullOrWhiteSpace($env:IDS_STABLE_RELEASE_TOKEN)) {
        throw 'IDS_STABLE_RELEASE_TOKEN is required. Configure the narrowly scoped stable automation credential; do not weaken main protection.'
    }
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        throw 'GH_TOKEN is required for authenticated stable release API operations.'
    }
}

function Get-IdsGitHubJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $raw = Invoke-IdsGitHub -Arguments $Arguments
    try {
        return ConvertFrom-Json -InputObject $raw -Depth 100 -ErrorAction Stop
    } catch {
        throw "GitHub CLI returned invalid JSON for '$($Arguments -join ' ')': $($_.Exception.Message)"
    }
}

function Get-IdsOptionalGitHubResource {
    param([Parameter(Mandatory)][string[]]$Arguments)

    try {
        return @{ exists = $true; value = (Get-IdsGitHubJson -Arguments $Arguments) }
    } catch {
        if ($_.Exception.Message -match '\bHTTP 404\b') {
            return @{ exists = $false; value = $null }
        }
        throw
    }
}

function Get-IdsRepositoryName {
    param([Parameter(Mandatory)][string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) { return $env:GITHUB_REPOSITORY }
    $remote = Invoke-IdsGit -Root $Root -Arguments @('remote', 'get-url', 'origin')
    if ($remote -match 'github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$') { return $Matches[1] }
    throw 'GITHUB_REPOSITORY is missing and origin is not a GitHub repository.'
}

function Get-IdsPromotionContext {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$PromotionSha,
        [Parameter(Mandatory)][string]$PromotionHeadSha
    )

    $pulls = @(Get-IdsGitHubJson -Arguments @(
        'api', "/repos/$Repository/commits/$PromotionSha/pulls?per_page=100"
    ))
    $matches = @($pulls | Where-Object {
        $_.merged_at -and
        $_.merge_commit_sha -ceq $PromotionSha -and
        $_.base.ref -ceq 'main' -and
        $_.head.ref -ceq 'beta' -and
        $_.head.repo.full_name -ceq $Repository
    })
    if ($matches.Count -ne 1) {
        throw 'Stable release requires exactly one merged, same-repository beta-to-main promotion PR associated with the merge commit.'
    }

    $checkResponse = Get-IdsGitHubJson -Arguments @(
        'api', "/repos/$Repository/commits/$PromotionHeadSha/check-runs?per_page=100"
    )
    $checkRuns = @($checkResponse.check_runs)
    foreach ($requiredName in @('quality', 'only-from-beta')) {
        $latest = @($checkRuns | Where-Object { $_.name -ceq $requiredName } |
            Sort-Object { [datetime]$_.started_at } -Descending |
            Select-Object -First 1)
        if (-not $latest.Count -or $latest[0].conclusion -cne 'success') {
            throw "Required beta check '$requiredName' did not succeed on promotion head $PromotionHeadSha."
        }
    }

    $labels = @($matches[0].labels | ForEach-Object { $_.name })
    return @{ pullRequest = $matches[0]; labels = $labels; betaHead = $PromotionHeadSha }
}

function Get-IdsPromotionParents {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$PromotionSha)

    $parents = (Invoke-IdsGit -Root $Root -Arguments @('rev-list', '--parents', '-n', '1', $PromotionSha)).Trim() -split '\s+'
    if ($parents.Count -ne 3 -or $parents[0] -cne $PromotionSha) {
        throw 'The stable promotion must be a two-parent merge commit on main.'
    }
    return @{ before = $parents[1]; betaHead = $parents[2] }
}

function Get-IdsNotesFromCommit {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Commit, [Parameter(Mandatory)][string]$NotesPath)

    $relative = [IO.Path]::GetRelativePath($Root, $NotesPath) -replace '\\', '/'
    try {
        Invoke-IdsGit -Root $Root -Arguments @('cat-file', '-e', "${Commit}:$relative") | Out-Null
    } catch {
        throw "Reviewed release notes are missing from the promotion: $relative"
    }
    $content = Invoke-IdsGit -Root $Root -Arguments @('show', "${Commit}:$relative")
    if (-not (Test-IdsReleaseNotes -Content $content)) {
        throw "Release notes '$relative' must be nonempty and contain user-facing changes, update guidance, runtime/dependency, data, and unverified-integration sections."
    }
    return $content
}

function Assert-IdsPromotionAndPlan {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Before,
        [Parameter(Mandatory)][string]$PromotionSha,
        [Parameter(Mandatory)][string]$Repository
    )

    foreach ($sha in @($Before, $PromotionSha)) {
        if ($sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Before and PromotionSha must be full lowercase 40-character commit SHAs.' }
    }
    $parents = Get-IdsPromotionParents -Root $Root -PromotionSha $PromotionSha
    if ($parents.before -cne $Before) { throw 'The supplied Before SHA must be the first parent of the beta-to-main promotion.' }

    $branch = (Invoke-IdsGit -Root $Root -Arguments @('branch', '--show-current')).Trim()
    if ($branch -cne 'main') { throw "Stable release transaction requires the local main branch; current branch is '$branch'." }
    $head = (Invoke-IdsGit -Root $Root -Arguments @('rev-parse', 'HEAD')).Trim()
    if ($head -cne $PromotionSha -and $head -notmatch '^[0-9a-f]{40}$') {
        throw 'The checked-out main head is not a valid full commit SHA.'
    }
    if ($head -cne $PromotionSha) {
        $isAncestor = $false
        try {
            Invoke-IdsGit -Root $Root -Arguments @('merge-base', '--is-ancestor', $PromotionSha, $head) | Out-Null
            $isAncestor = $true
        } catch { }
        if (-not $isAncestor) { throw 'The checked-out main head does not contain the requested promotion.' }
    }

    $status = (Invoke-IdsGit -Root $Root -Arguments @('status', '--porcelain', '--untracked-files=all')).Trim()
    if ($status) { throw 'Stable release requires a clean checkout. Commit or remove local changes before running the transaction.' }

    $parents = Get-IdsPromotionParents -Root $Root -PromotionSha $PromotionSha
    $context = Get-IdsPromotionContext -Repository $Repository -PromotionSha $PromotionSha -PromotionHeadSha $parents.betaHead
    $plan = Get-IdsReleasePlan -Root $Root -Before $Before -After $PromotionSha -Labels $context.labels
    if ($plan.required) {
        [void](Get-IdsNotesFromCommit -Root $Root -Commit $PromotionSha -NotesPath $plan.notesPath)
    }
    return @{ plan = $plan; context = $context; parents = $parents }
}

function Get-IdsRemoteBranchHead {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Branch)

    $lines = Invoke-IdsGit -Root $Root -Arguments @('ls-remote', '--heads', 'origin', "refs/heads/$Branch")
    $match = [regex]::Match($lines, '(?m)^([0-9a-f]{40})\s+refs/heads/' + [regex]::Escape($Branch) + '$')
    if (-not $match.Success) { throw "Remote origin does not contain refs/heads/$Branch." }
    return $match.Groups[1].Value
}

function Get-IdsReadOnlyMainHead {
    param([Parameter(Mandatory)][string]$Repository)

    $ref = Get-IdsGitHubJson -Arguments @('api', "/repos/$Repository/git/ref/heads/main")
    if ($ref.object.sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Read-only main ref API returned an invalid commit SHA.' }
    return $ref.object.sha
}

function Invoke-IdsStableArtifactBuild {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$SourceCommit
    )

    & (Join-Path $Root 'Build-Package.ps1') -OutputPath $OutputPath -Channel stable -SourceCommit $SourceCommit
    if ($LASTEXITCODE -ne 0) { throw 'Stable ZIP build failed.' }
}

function Get-IdsCompleteActionsCollection {
    param([Parameter(Mandatory)][string]$Endpoint, [Parameter(Mandatory)][string]$Property)

    $pages = @(Get-IdsGitHubJson -Arguments @('api', $Endpoint, '--paginate', '--slurp'))
    if (-not $pages.Count) { throw "Actions $Property listing is incomplete; absence cannot be verified." }
    $records = @()
    foreach ($page in $pages) {
        if ($null -eq $page.total_count -or $null -eq $page.$Property) {
            throw "Actions $Property listing is malformed; absence cannot be verified."
        }
        $records += @($page.$Property)
    }
    if ($records.Count -ne $pages[0].total_count) {
        throw "Actions $Property listing is incomplete or changed during pagination; absence cannot be verified."
    }
    return $records
}

function Assert-IdsNoPriorArtifactUpload {
    param([string]$Repository, [string]$PromotionSha, [string]$VersionCommit)

    foreach ($sha in @($PromotionSha, $VersionCommit)) {
        $runs = @(Get-IdsCompleteActionsCollection -Endpoint "/repos/$Repository/actions/workflows/release.yml/runs?per_page=100&head_sha=$sha" -Property workflow_runs)
        foreach ($run in $runs) {
            if ([string]$run.id -cnotmatch '^[1-9][0-9]*$') { throw 'Actions run identity is invalid; artifact absence cannot be verified.' }
            $jobs = @(Get-IdsCompleteActionsCollection -Endpoint "/repos/$Repository/actions/runs/$($run.id)/jobs?per_page=100&filter=all" -Property jobs)
            foreach ($job in $jobs) {
                if ($null -eq $job.steps) { throw 'Actions job steps unavailable; artifact absence cannot be verified.' }
                foreach ($step in $job.steps) {
                    if ($step.name -ceq 'Upload stable ZIP and immutable manifest' -and $step.conclusion -ceq 'success') {
                        throw 'An immutable artifact was previously persisted but is now missing. Never rebuild or replace recorded bytes.'
                    }
                }
            }
        }
    }
}

function Initialize-IdsStableArtifact {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$VersionCommit,
        [Parameter(Mandatory)][string]$PromotionSha,
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [string]$ArtifactRunId
    )

    $tag = Get-IdsOptionalGitHubResource -Arguments @('api', "/repos/$Repository/git/ref/tags/$($Plan.tag)")
    $release = Get-IdsOptionalGitHubResource -Arguments @('api', "/repos/$Repository/releases/tags/$($Plan.tag)")
    if ($release.exists) {
        Write-Host 'Release already exists; skip artifact construction and verify published evidence during publication recovery.'
        Write-IdsWorkflowOutput -Values @{ artifact_created = 'false' }
        return @{ created = $false }
    }
    if ($tag.exists) { throw 'Existing tag without release blocks artifact construction; do not replace published evidence.' }
    if ((Test-Path -LiteralPath $ArtifactDirectory) -and
        @(Get-ChildItem -LiteralPath $ArtifactDirectory -Force).Count) {
        throw 'Artifact destination already contains bytes. Refusing to replace them.'
    }

    $name = "IntuneDocsStudio-stable-$($Plan.version)-$VersionCommit"
    # Inspect every page, including expired records. API failures are not evidence of absence.
    $records = @(Get-IdsCompleteActionsCollection -Endpoint "/repos/$Repository/actions/artifacts?per_page=100&name=$name" -Property artifacts)
    if (@($records | Where-Object { $_.name -cne $name }).Count) {
        throw 'Artifact listing returned unexpected identities; absence cannot be verified.'
    }
    if ($records.Count -gt 1) { throw 'Multiple immutable artifacts recorded for this identity; stop and investigate.' }
    if ($records.Count) {
        $record = $records[0]
        if ($record.expired -ne $false) { throw 'The recorded immutable artifact is expired or unavailable; never rebuild or replace it.' }
        $runId = [string]$record.workflow_run.id
        if ($runId -cnotmatch '^[1-9][0-9]*$' -or ($ArtifactRunId -and $ArtifactRunId -cne $runId)) {
            throw 'Recorded artifact does not match the requested source run.'
        }
        $run = Get-IdsGitHubJson -Arguments @('api', "/repos/$Repository/actions/runs/$runId")
        if ($run.path -cne '.github/workflows/release.yml' -or
            $run.event -cnotin @('push', 'workflow_dispatch') -or
            $run.head_sha -cnotin @($PromotionSha, $VersionCommit)) {
            throw 'Recorded artifact source run does not identify this stable promotion or version commit.'
        }
        Invoke-IdsGitHub -Arguments @('run', 'download', $runId, '--repo', $Repository, '--name', $name, '--dir', $ArtifactDirectory) | Out-Null
        [void](Assert-IdsArtifactIdentity -ArtifactDirectory $ArtifactDirectory -Version $Plan.version `
            -PromotionSha $PromotionSha -VersionCommit $VersionCommit)
        $created = $false
    } else {
        if ($ArtifactRunId) { throw 'Requested immutable artifact run has no recorded artifact; do not rebuild or replace it.' }
        Assert-IdsNoPriorArtifactUpload -Repository $Repository -PromotionSha $PromotionSha -VersionCommit $VersionCommit
        Invoke-IdsStableArtifactBuild -Root $Root -OutputPath $ArtifactDirectory -SourceCommit $VersionCommit
        [void](Write-IdsReleaseManifest -ArtifactDirectory $ArtifactDirectory -Version $Plan.version `
            -PromotionSha $PromotionSha -VersionCommit $VersionCommit)
        $created = $true
    }
    Write-IdsWorkflowOutput -Values @{ artifact_created = $created.ToString().ToLowerInvariant() }
    return @{ created = $created }
}

function Assert-IdsNoExistingRelease {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Tag)

    $tagRef = Get-IdsOptionalGitHubResource -Arguments @('api', "/repos/$Repository/git/ref/tags/$Tag")
    $release = Get-IdsOptionalGitHubResource -Arguments @('api', "/repos/$Repository/releases/tags/$Tag")
    if ($tagRef.exists -or $release.exists) {
        throw "Refusing to overwrite existing stable tag or release '$Tag'. Stop and inspect the existing publication."
    }
}

function New-IdsVersionCommit {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$PromotionSha,
        [Parameter(Mandatory)][string]$Version
    )

    $versionPath = Join-Path $Root 'VERSION'
    [IO.File]::WriteAllText($versionPath, "$Version`n", [Text.UTF8Encoding]::new($false))
    Invoke-IdsGit -Root $Root -Arguments @('add', '--', 'VERSION') | Out-Null
    $stagedOutput = Invoke-IdsGit -Root $Root -Arguments @('diff', '--cached', '--name-only')
    $staged = @($stagedOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($staged.Count -ne 1 -or $staged[0] -cne 'VERSION') {
        throw 'Stable version commit must contain only VERSION.'
    }

    Invoke-IdsGit -Root $Root -Arguments @(
        '-c', 'user.name=github-actions[bot]',
        '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
        'commit', '-m', "chore(release): $Version",
        '-m', "Release-Promotion: $PromotionSha"
    ) | Out-Null
    return (Invoke-IdsGit -Root $Root -Arguments @('rev-parse', 'HEAD')).Trim()
}

function Assert-IdsVersionCommit {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Before,
        [Parameter(Mandatory)][string]$PromotionSha,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][hashtable]$Plan
    )

    if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'RecoveryVersionCommit must be a full lowercase 40-character commit SHA.' }
    Invoke-IdsGit -Root $Root -Arguments @('cat-file', '-e', $Commit) | Out-Null
    $parents = (Invoke-IdsGit -Root $Root -Arguments @('rev-list', '--parents', '-n', '1', $Commit)).Trim() -split '\s+'
    if ($parents.Count -ne 2 -or $parents[1] -cne $PromotionSha) {
        throw 'Recovery version commit must be the single direct child of the original promotion.'
    }
    $message = Invoke-IdsGit -Root $Root -Arguments @('show', '-s', '--format=%B', $Commit)
    if ($message -notmatch "(?m)^Release-Promotion:\s*$([regex]::Escape($PromotionSha))\s*$") {
        throw 'Recovery version commit is missing the exact Release-Promotion trailer.'
    }
    $changedOutput = Invoke-IdsGit -Root $Root -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', $Commit)
    $changed = @($changedOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($changed.Count -ne 1 -or $changed[0] -cne 'VERSION') {
        throw 'Recovery version commit may change VERSION only.'
    }
    $actualVersion = ((Invoke-IdsGit -Root $Root -Arguments @('show', "${Commit}:VERSION"))).Trim()
    if ($actualVersion -cne $Plan.version) { throw 'Recovery version commit does not contain the exact planned version.' }
    [void](Get-IdsNotesFromCommit -Root $Root -Commit $Commit -NotesPath $Plan.notesPath)
}

function Write-IdsReleaseManifest {
    param(
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$PromotionSha,
        [Parameter(Mandatory)][string]$VersionCommit
    )

    $zipPath = Join-Path $ArtifactDirectory 'IntuneDocsStudio.zip'
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw 'Stable ZIP build is missing.' }
    $sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        version      = $Version
        tag          = "v$Version"
        channel      = 'stable'
        sourceCommit = $VersionCommit
        promotionSha = $PromotionSha
        zipSha256    = $sha256
    }
    $manifestPath = Join-Path $ArtifactDirectory 'release-manifest.json'
    [IO.File]::WriteAllText(
        $manifestPath,
        (($manifest | ConvertTo-Json -Compress) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    return @{ path = $manifestPath; sha256 = $sha256; zip = $zipPath; manifest = $manifest }
}

function Write-IdsWorkflowOutput {
    param([Parameter(Mandatory)][hashtable]$Values)

    if (-not $env:GITHUB_OUTPUT) { return }
    $lines = foreach ($key in $Values.Keys) { "$key=$($Values[$key])" }
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

function Assert-IdsArtifactIdentity {
    param(
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$PromotionSha,
        [Parameter(Mandatory)][string]$VersionCommit
    )

    $zipPath = Join-Path $ArtifactDirectory 'IntuneDocsStudio.zip'
    $manifestPath = Join-Path $ArtifactDirectory 'release-manifest.json'
    foreach ($path in @($zipPath, $manifestPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Stable artifact evidence is incomplete: missing '$([IO.Path]::GetFileName($path))'. Retry with the original workflow artifact; do not rebuild or replace it."
        }
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'Stable release manifest is not valid JSON.'
    }
    $checksum = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifest.channel -cne 'stable' -or
        $manifest.version -cne $Version -or
        $manifest.tag -cne "v$Version" -or
        $manifest.sourceCommit -cne $VersionCommit -or
        $manifest.promotionSha -cne $PromotionSha -or
        $manifest.zipSha256 -cne $checksum) {
        throw 'Stable artifact identity or checksum does not match the recorded promotion and version commit. Refusing publication.'
    }
    return @{ zip = $zipPath; manifest = $manifestPath; sha256 = $checksum }
}

function Assert-IdsPublishedRelease {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$VersionCommit,
        [Parameter(Mandatory)][string]$ZipSha256,
        [Parameter(Mandatory)][string]$ManifestSha256,
        [Parameter(Mandatory)][string]$NotesPath
    )

    $tagRef = Get-IdsOptionalGitHubResource -Arguments @('api', "/repos/$Repository/git/ref/tags/$Tag")
    if (-not $tagRef.exists) { throw "Release '$Tag' exists without its Git tag; recovery will not recreate or overwrite it." }
    $tagObject = $tagRef.value.object
    if ($tagObject.type -ceq 'tag') {
        $annotated = Get-IdsGitHubJson -Arguments @('api', "/repos/$Repository/git/tags/$($tagObject.sha)")
        $tagCommit = $annotated.object.sha
    } else {
        $tagCommit = $tagObject.sha
    }
    if ($tagCommit -cne $VersionCommit) { throw "Tag '$Tag' does not identify the recorded stable version commit." }

    $releaseResource = Get-IdsOptionalGitHubResource -Arguments @('api', "/repos/$Repository/releases/tags/$Tag")
    if (-not $releaseResource.exists) { throw "Tag '$Tag' exists but its GitHub Release is absent; recovery will not replace the tag." }
    $release = $releaseResource.value
    if ($release.tag_name -cne $Tag -or $release.draft -or $release.prerelease) {
        throw "Existing '$Tag' is not the expected published stable release."
    }
    $expectedNotes = [IO.File]::ReadAllText($NotesPath).Trim()
    if ([string]$release.body -cne $expectedNotes) {
        throw "Existing '$Tag' release notes do not match the reviewed promotion notes."
    }
    $assets = @{}
    foreach ($asset in $release.assets) { $assets[$asset.name] = $asset.digest }
    if ($assets['IntuneDocsStudio.zip'] -cne "sha256:$ZipSha256" -or
        $assets['release-manifest.json'] -cne "sha256:$ManifestSha256") {
        throw "Existing '$Tag' assets do not match the immutable release artifact. Do not replace them."
    }
    $latest = Get-IdsGitHubJson -Arguments @('api', "/repos/$Repository/releases/latest")
    if ($latest.tag_name -cne $Tag) { throw "Stable release '$Tag' is not marked latest." }
}

function Invoke-IdsPublish {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$VersionCommit,
        [Parameter(Mandatory)][string]$PromotionSha,
        [string]$ArtifactDirectory
    )

    $tagResource = Get-IdsOptionalGitHubResource -Arguments @('api', "/repos/$Repository/git/ref/tags/$($Plan.tag)")
    $releaseResource = Get-IdsOptionalGitHubResource -Arguments @('api', "/repos/$Repository/releases/tags/$($Plan.tag)")

    if ($releaseResource.exists) {
        Write-Host "Release $($Plan.tag) already exists; verifying its immutable tag and assets, then retrying only beta back-sync."
        if ($ArtifactDirectory -and (Test-Path -LiteralPath (Join-Path $ArtifactDirectory 'release-manifest.json') -PathType Leaf)) {
            $artifact = Assert-IdsArtifactIdentity -ArtifactDirectory $ArtifactDirectory `
                -Version $Plan.version -PromotionSha $PromotionSha -VersionCommit $VersionCommit
            $manifestSha = (Get-FileHash -LiteralPath $artifact.manifest -Algorithm SHA256).Hash.ToLowerInvariant()
        } else {
            $downloadDirectory = Join-Path $Root ('.ids-release-verify-' + [guid]::NewGuid().ToString('N'))
            try {
                [void](New-Item -ItemType Directory -Path $downloadDirectory -Force)
                Invoke-IdsGitHub -Arguments @(
                    'release', 'download', $Plan.tag, '--repo', $Repository,
                    '--pattern', 'release-manifest.json', '--dir', $downloadDirectory
                ) | Out-Null
                $remoteManifest = Join-Path $downloadDirectory 'release-manifest.json'
                if (-not (Test-Path -LiteralPath $remoteManifest -PathType Leaf)) {
                    throw "Existing '$($Plan.tag)' has no release-manifest.json asset."
                }
                $identity = Get-Content -LiteralPath $remoteManifest -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($identity.channel -cne 'stable' -or $identity.version -cne $Plan.version -or
                    $identity.tag -cne $Plan.tag -or $identity.sourceCommit -cne $VersionCommit -or
                    $identity.promotionSha -cne $PromotionSha) {
                    throw "Existing '$($Plan.tag)' manifest does not identify this exact stable promotion and version commit."
                }
                $manifestSha = (Get-FileHash -LiteralPath $remoteManifest -Algorithm SHA256).Hash.ToLowerInvariant()
                $assetMap = @{}
                foreach ($asset in $releaseResource.value.assets) { $assetMap[$asset.name] = $asset.digest }
                if ($assetMap['release-manifest.json'] -cne "sha256:$manifestSha" -or
                    $assetMap['IntuneDocsStudio.zip'] -cne "sha256:$($identity.zipSha256)") {
                    throw "Existing '$($Plan.tag)' release assets do not match its immutable manifest."
                }
                $artifact = @{ sha256 = [string]$identity.zipSha256 }
            } finally {
                if (Test-Path -LiteralPath $downloadDirectory) {
                    Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        Assert-IdsPublishedRelease -Repository $Repository -Tag $Plan.tag -VersionCommit $VersionCommit `
            -ZipSha256 $artifact.sha256 -ManifestSha256 $manifestSha -NotesPath $Plan.notesPath
    } elseif ($tagResource.exists) {
        throw "Tag '$($Plan.tag)' exists without its release. Refusing to recreate or overwrite either resource."
    } else {
        if (-not $ArtifactDirectory) {
            throw 'The release is not published and the original stable artifact was not supplied. Recover with the original artifact_run_id; do not rebuild or replace it.'
        }
        $artifact = Assert-IdsArtifactIdentity -ArtifactDirectory $ArtifactDirectory `
            -Version $Plan.version -PromotionSha $PromotionSha -VersionCommit $VersionCommit
        $manifestSha = (Get-FileHash -LiteralPath $artifact.manifest -Algorithm SHA256).Hash.ToLowerInvariant()
        Invoke-IdsGitHub -Arguments @(
            'release', 'create', $Plan.tag, $artifact.zip, $artifact.manifest,
            '--repo', $Repository, '--target', $VersionCommit,
            '--notes-file', $Plan.notesPath, '--latest'
        ) | Out-Null
        Assert-IdsPublishedRelease -Repository $Repository -Tag $Plan.tag -VersionCommit $VersionCommit `
            -ZipSha256 $artifact.sha256 -ManifestSha256 $manifestSha -NotesPath $Plan.notesPath
    }
    Write-Host "Stable release verified: $($Plan.tag) ($VersionCommit; SHA256 $($artifact.sha256))."
}

function Invoke-IdsValidationAndBuild {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][ValidateSet('beta', 'stable')][string]$Channel,
        [Parameter(Mandatory)][string]$SourceCommit
    )

    if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
        throw 'Pester is unavailable; install the pinned Pester 5.7.1 before stable validation.'
    }
    $pester = Invoke-Pester -Path (Join-Path $Root 'tests') -Output Detailed -PassThru
    if ($pester.FailedCount -or $pester.NotRunCount -or $pester.PassedCount -eq 0) {
        throw 'PowerShell tests failed at the exact stable/beta source commit.'
    }
    & node --test (Join-Path $Root 'tests\publishing-ui.test.js')
    if ($LASTEXITCODE -ne 0) { throw 'Node dashboard tests failed at the exact stable/beta source commit.' }
    & (Join-Path $Root 'scripts\Test-Repository.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Repository policy validation failed at the exact stable/beta source commit.' }
    & (Join-Path $Root 'Build-Package.ps1') -OutputPath $OutputPath -Channel $Channel -SourceCommit $SourceCommit
    if ($LASTEXITCODE -ne 0) { throw 'Product ZIP build failed at the exact stable/beta source commit.' }
}

function Invoke-IdsBackMerge {
    param([Parameter(Mandatory)][string]$Root)

    $path = Join-Path $Root ('.ids-release-backmerge-' + [guid]::NewGuid().ToString('N'))
    $worktreeAdded = $false
    try {
        Invoke-IdsGit -Root $Root -Arguments @('fetch', '--no-tags', 'origin', 'main', 'beta') | Out-Null
        Invoke-IdsGit -Root $Root -Arguments @('worktree', 'add', '--detach', $path, 'refs/remotes/origin/beta') | Out-Null
        $worktreeAdded = $true
        $branch = 'ids-release-backmerge-' + [guid]::NewGuid().ToString('N')
        Invoke-IdsGit -Root $path -Arguments @('switch', '-c', $branch) | Out-Null
        try {
            Invoke-IdsGit -Root $path -Arguments @(
                '-c', 'user.name=github-actions[bot]',
                '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
                'merge', '--no-ff', '--no-edit', 'refs/remotes/origin/main'
            ) | Out-Null
        } catch {
            throw "Back-merge main into beta has conflicts. Resolve them in a reviewed change; no automatic conflict resolution was attempted. $($_.Exception.Message)"
        }
        $head = (Invoke-IdsGit -Root $path -Arguments @('rev-parse', 'HEAD')).Trim()
        $output = Join-Path $path '.ids-beta-validation'
        Invoke-IdsValidationAndBuild -Root $path -OutputPath $output -Channel beta -SourceCommit $head
        Invoke-IdsGit -Root $path -Arguments @('push', 'origin', "HEAD:refs/heads/beta") | Out-Null
        Write-Host "Back-merged and validated beta head $head."
    } finally {
        if ($worktreeAdded) {
            Invoke-IdsGit -Root $Root -Arguments @('worktree', 'remove', '--force', $path) | Out-Null
            Invoke-IdsGit -Root $Root -Arguments @('worktree', 'prune') | Out-Null
        } elseif (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

function Invoke-IdsStableRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Before,
        [Parameter(Mandatory)][string]$PromotionSha,
        [string]$RecoveryVersionCommit,
        [switch]$PlanOnly,
        [switch]$PrepareOnly,
        [switch]$PublishPrepared,
        [switch]$PrepareArtifact,
        [string]$ArtifactDirectory,
        [string]$ArtifactRunId,
        [string]$Repository
    )

    $selectedPhases = @()
    if ($PlanOnly) { $selectedPhases += 'PlanOnly' }
    if ($PrepareOnly) { $selectedPhases += 'PrepareOnly' }
    if ($PublishPrepared) { $selectedPhases += 'PublishPrepared' }
    if ($PrepareArtifact) { $selectedPhases += 'PrepareArtifact' }
    if ($selectedPhases.Count -gt 1) {
        throw 'Choose only one of PlanOnly, PrepareOnly, PrepareArtifact, or PublishPrepared.'
    }
    if (($PublishPrepared -or $PrepareArtifact) -and -not $RecoveryVersionCommit) {
        throw 'Artifact preparation and publication require the recorded RecoveryVersionCommit.'
    }
    if ($RecoveryVersionCommit -and -not $PublishPrepared -and -not $PrepareOnly -and -not $PrepareArtifact) {
        throw 'RecoveryVersionCommit is accepted only with PrepareArtifact, PublishPrepared or PrepareOnly.'
    }

    $rootPath = [IO.Path]::GetFullPath($Root)
    if (-not $Repository) { $Repository = Get-IdsRepositoryName -Root $rootPath }
    $validated = Assert-IdsPromotionAndPlan -Root $rootPath -Before $Before `
        -PromotionSha $PromotionSha -Repository $Repository
    $plan = $validated.plan
    if (-not $plan.required) {
        $localMain = (Invoke-IdsGit -Root $rootPath -Arguments @('rev-parse', 'HEAD')).Trim()
        $remoteMain = Get-IdsReadOnlyMainHead -Repository $Repository
        if ($localMain -cne $PromotionSha -or $remoteMain -cne $PromotionSha) {
            throw "Documentation-only promotion is stale: expected local and remote main head $PromotionSha."
        }
        Write-Host "No stable release required: promotion $PromotionSha changes documentation only."
        Write-IdsWorkflowOutput -Values @{
            required = 'false'
            version = $plan.version
            tag = $plan.tag
            promotion_sha = $PromotionSha
        }
        return $plan
    }

    if ($PlanOnly) {
        Write-IdsWorkflowOutput -Values @{
            required = 'true'
            version = $plan.version
            tag = $plan.tag
            promotion_sha = $PromotionSha
        }
        Write-Host "Stable release required: version $($plan.version), tag $($plan.tag)."
        return $plan
    }

    Assert-IdsStableCredential

    if ($PublishPrepared -or $PrepareArtifact) {
        $commit = $RecoveryVersionCommit
        Assert-IdsVersionCommit -Root $rootPath -Before $Before -PromotionSha $PromotionSha -Commit $commit -Plan $plan
        $remoteMain = Get-IdsRemoteBranchHead -Root $rootPath -Branch 'main'
        if ($remoteMain -cne $commit) {
            throw "Remote main moved from the recorded version commit $commit to $remoteMain. Stop and investigate; do not force-push."
        }
        $currentHead = (Invoke-IdsGit -Root $rootPath -Arguments @('rev-parse', 'HEAD')).Trim()
        if ($currentHead -cne $commit) { throw 'Artifact preparation and publication must run from the exact recorded version commit.' }
        if ($PrepareArtifact) {
            if (-not $ArtifactDirectory) { throw 'PrepareArtifact requires an artifact destination directory.' }
            return Initialize-IdsStableArtifact -Root $rootPath -Repository $Repository -Plan $plan `
                -VersionCommit $commit -PromotionSha $PromotionSha -ArtifactDirectory $ArtifactDirectory -ArtifactRunId $ArtifactRunId
        }
        Invoke-IdsPublish -Root $rootPath -Repository $Repository -Plan $plan -VersionCommit $commit `
            -PromotionSha $PromotionSha -ArtifactDirectory $ArtifactDirectory
        Invoke-IdsBackMerge -Root $rootPath
        return @{ version = $plan.version; tag = $plan.tag; commit = $commit; promotionSha = $PromotionSha }
    }

    if ($RecoveryVersionCommit) {
        $commit = $RecoveryVersionCommit
        Assert-IdsVersionCommit -Root $rootPath -Before $Before -PromotionSha $PromotionSha -Commit $commit -Plan $plan
        $remoteMain = Get-IdsRemoteBranchHead -Root $rootPath -Branch 'main'
        $currentHead = (Invoke-IdsGit -Root $rootPath -Arguments @('rev-parse', 'HEAD')).Trim()
        if ($remoteMain -cne $commit -or $currentHead -cne $commit) {
            throw 'Recovery must use the exact recorded version commit at both local and remote main; no increment or force-push is allowed.'
        }
    } else {
        $branch = (Invoke-IdsGit -Root $rootPath -Arguments @('branch', '--show-current')).Trim()
        if ($branch -cne 'main') { throw "Stable release transaction requires the local main branch; current branch is '$branch'." }
        $remoteMain = Get-IdsRemoteBranchHead -Root $rootPath -Branch 'main'
        if ($remoteMain -cne $PromotionSha) {
            throw "Expected remote main head $PromotionSha, but found $remoteMain. Promotion is stale; no version commit was created."
        }
        $currentHead = (Invoke-IdsGit -Root $rootPath -Arguments @('rev-parse', 'HEAD')).Trim()
        if ($currentHead -cne $PromotionSha) {
            throw "Stable version commit must be based on the exact promotion SHA $PromotionSha; local main is $currentHead."
        }
        Assert-IdsNoExistingRelease -Repository $Repository -Tag $plan.tag
        $commit = New-IdsVersionCommit -Root $rootPath -PromotionSha $PromotionSha -Version $plan.version
        if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw 'The generated version commit did not resolve to a full SHA.' }
        try {
            Invoke-IdsGit -Root $rootPath -Arguments @('push', 'origin', "$($commit):refs/heads/main") | Out-Null
        } catch {
            throw "Pushing version commit $commit to protected main failed. No release will be created. Verify the configured narrow credential and protection settings; do not weaken main. $($_.Exception.Message)"
        }
    }

    if ($PrepareOnly) {
        Write-IdsWorkflowOutput -Values @{
            required = 'true'
            version = $plan.version
            tag = $plan.tag
            version_commit = $commit
            promotion_sha = $PromotionSha
        }
        Write-Host "Prepared stable version $($plan.version), tag $($plan.tag), commit $commit."
        return @{ version = $plan.version; tag = $plan.tag; commit = $commit; promotionSha = $PromotionSha }
    }

    $scratch = Join-Path $rootPath ('.ids-stable-release-' + [guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path $scratch -Force)
        Invoke-IdsValidationAndBuild -Root $rootPath -OutputPath $scratch -Channel stable -SourceCommit $commit
        $artifact = Write-IdsReleaseManifest -ArtifactDirectory $scratch -Version $plan.version `
            -PromotionSha $PromotionSha -VersionCommit $commit
        Invoke-IdsPublish -Root $rootPath -Repository $Repository -Plan $plan -VersionCommit $commit `
            -PromotionSha $PromotionSha -ArtifactDirectory $scratch
        Invoke-IdsBackMerge -Root $rootPath
        return @{ version = $plan.version; tag = $plan.tag; commit = $commit; promotionSha = $PromotionSha; zipSha256 = $artifact.sha256 }
    } finally {
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Before -or -not $PromotionSha) {
        throw 'Usage: Invoke-StableRelease.ps1 -Before <sha> -PromotionSha <sha> [-RecoveryVersionCommit <sha>].'
    }
    Invoke-IdsStableRelease -Root (Split-Path -Parent $PSScriptRoot) -Before $Before -PromotionSha $PromotionSha `
        -RecoveryVersionCommit $RecoveryVersionCommit -PlanOnly:$PlanOnly -PrepareOnly:$PrepareOnly `
        -PublishPrepared:$PublishPrepared -PrepareArtifact:$PrepareArtifact -ArtifactDirectory $ArtifactDirectory -ArtifactRunId $ArtifactRunId
}
