function Test-IdsAgentInstructions {
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Root)

    $violations = [System.Collections.Generic.List[string]]::new()
    $rootPath = [System.IO.Path]::GetFullPath($Root)

    $canonicalPath = Join-Path $rootPath 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
        $violations.Add('AGENTS.md is missing. Add the single canonical repository policy before using client instruction pointers.')
    } elseif ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $canonicalPath -Raw))) {
        $violations.Add('AGENTS.md is empty. Put the canonical repository policy in this file.')
    }

    $pointers = @(
        [pscustomobject]@{
            Path = 'CLAUDE.md'
            Content = "# Contributor guidance`n`nRead [AGENTS.md](AGENTS.md) for the canonical repository guidance."
        }
        [pscustomobject]@{
            Path = '.github/copilot-instructions.md'
            Content = "# Copilot guidance`n`nRead [AGENTS.md](../AGENTS.md) for the canonical repository guidance."
        }
    )
    foreach ($pointer in $pointers) {
        $path = Join-Path $rootPath ($pointer.Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $violations.Add("$($pointer.Path) is missing. Restore the thin pointer to the canonical AGENTS.md.")
            continue
        }

        $actual = (Get-Content -LiteralPath $path -Raw) -replace "`r`n", "`n"
        $expected = $pointer.Content -replace "`r`n", "`n"
        if ($actual.Trim() -cne $expected.Trim()) {
            $violations.Add("$($pointer.Path) must contain only its canonical AGENTS.md pointer; remove copied policy prose and restore the pointer template.")
        }
    }

    $matrixPath = Join-Path $rootPath 'docs\baseline-adoption.md'
    $requiredControls = @(
        'B-01', 'B-02', 'B-03', 'B-04', 'B-05', 'B-06', 'B-07',
        'B-08', 'B-09', 'B-10', 'B-11', 'B-12', 'B-13'
    )
    if (-not (Test-Path -LiteralPath $matrixPath -PathType Leaf)) {
        $violations.Add('docs/baseline-adoption.md is missing. Add the applicable baseline control matrix, including deferred and non-applicable items.')
    } else {
        $rows = Get-Content -LiteralPath $matrixPath |
            Where-Object { $_ -match '^\|\s*B-\d+\s*\|' }
        foreach ($control in $requiredControls) {
            $matchingRows = @($rows | Where-Object { $_ -match "^\|\s*$control\s*\|" })
            if ($matchingRows.Count -eq 0) {
                $violations.Add("docs/baseline-adoption.md is missing required control row $control. Record its applicability, actual control/evidence, and honest status.")
                continue
            }

            if ($matchingRows.Count -gt 1) {
                $violations.Add("docs/baseline-adoption.md contains duplicate control row $control. Keep one current evidence and status row.")
                continue
            }

            $row = [regex]::Match(
                $matchingRows[0],
                '^\|\s*(B-\d+)\s*\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|'
            )
            if (-not $row.Success) {
                $violations.Add("docs/baseline-adoption.md control row $control is malformed. Include applicability, a named control/evidence, and a status or reason.")
                continue
            }

            $evidence = $row.Groups[5].Value.Trim()
            $status = $row.Groups[6].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($evidence) -or $evidence -notmatch '`[^`]+`') {
                $violations.Add("docs/baseline-adoption.md control row $control must name a script, test, workflow, runtime interface, or review requirement in its control evidence.")
            }
            if ([string]::IsNullOrWhiteSpace($status)) {
                $violations.Add("docs/baseline-adoption.md control row $control must state its status, limits, or reason.")
            }
        }
    }

    return $violations.ToArray()
}

function Test-IdsVersionChange {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Before,
        [Parameter(Mandatory)][string]$After
    )

    $violations = [System.Collections.Generic.List[string]]::new()
    $rootPath = [System.IO.Path]::GetFullPath($Root)

    foreach ($commit in @($Before, $After)) {
        & git -C $rootPath cat-file -e $commit 2>$null
        if ($LASTEXITCODE -ne 0) {
            $violations.Add("Cannot validate VERSION policy because commit '$commit' does not exist in this repository.")
            return $violations.ToArray()
        }
    }

    $beforeBlob = & git -C $rootPath rev-parse --verify "${Before}:VERSION" 2>$null
    $beforeExists = $LASTEXITCODE -eq 0
    $afterBlob = & git -C $rootPath rev-parse --verify "${After}:VERSION" 2>$null
    $afterExists = $LASTEXITCODE -eq 0

    if (-not $beforeExists -and -not $afterExists) {
        return $violations.ToArray()
    }

    if (-not $beforeExists -and $afterExists) {
        $afterContents = (& git -C $rootPath show "${After}:VERSION" 2>$null) -join "`n"
        $afterContents = $afterContents.TrimEnd([char[]]"`r`n")
        if ($afterContents -cne '0.1.0') {
            $violations.Add("VERSION may be bootstrapped only as the exact value 0.1.0. Remove this edit or set VERSION to 0.1.0 for the one-time bootstrap.")
        }
        return $violations.ToArray()
    }

    if ($beforeExists -and -not $afterExists) {
        $violations.Add('VERSION cannot be removed after bootstrap. Restore the base VERSION value; version changes are reserved for the stable-release pipeline.')
        return $violations.ToArray()
    }

    if ($beforeBlob -cne $afterBlob) {
        $violations.Add('Feature pull requests must not edit VERSION after bootstrap, even to a numerically higher value. Revert the VERSION change; the stable-release pipeline owns version increments.')
    }

    return $violations.ToArray()
}

function Test-IdsVersionFormat {
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Root)

    $path = Join-Path ([System.IO.Path]::GetFullPath($Root)) 'VERSION'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @('VERSION is missing. Add the strict MAJOR.MINOR.PATCH version file.')
    }

    $version = [System.IO.File]::ReadAllText($path).Trim()
    if ($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        return @('VERSION must contain a strict MAJOR.MINOR.PATCH value without prefixes, leading zeroes, or prerelease/build metadata.')
    }

    return @()
}

function Test-IdsPullRequestTarget {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][bool]$SameRepository
    )

    if ($Base -ceq 'main' -and ($Head -cne 'beta' -or -not $SameRepository)) {
        return @('main accepts only a promotion from beta in this repository. Retarget feature PRs to beta.')
    }
    if ($Base -cne 'beta' -and $Base -cne 'main') {
        return @('Target beta for feature work; main is reserved for owner-requested promotions.')
    }
    return @()
}
