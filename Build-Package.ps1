<#
    Build-Package.ps1 — creates the customer ZIP from an explicit product allowlist.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'IntuneDocsStudio-share'),
    [ValidateSet('beta', 'stable')][string]$Channel = 'beta',
    [string]$SourceCommit
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot

if (-not [IO.Path]::IsPathRooted($OutputPath)) {
    throw 'OutputPath must be an absolute folder path.'
}
if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
    throw 'OutputPath must be a folder, not a file.'
}

$hasSourceCommit = $PSBoundParameters.ContainsKey('SourceCommit')
if ($hasSourceCommit -and $SourceCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw 'SourceCommit must be a full 40-character lowercase hexadecimal SHA.'
}
if ($Channel -eq 'stable' -and -not $hasSourceCommit) {
    throw 'Stable packages require an explicit full source commit SHA.'
}
$commit = if ($hasSourceCommit) { $SourceCommit } else { 'development' }

$requiredFiles = @(
    'Start-IntuneDocs.cmd'
    'IntuneDocsStudio.ps1'
    'VERSION'
    'README.md'
    'QUICKSTART.md'
    'SECURITY.md'
    'docs\publishing.md'
    'web\index.html'
    'web\app.js'
    'web\style.css'
)
$relativeFiles = [System.Collections.Generic.List[string]]::new()
$relativeFiles.AddRange([string[]]$requiredFiles)

foreach ($required in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $src $required) -PathType Leaf)) {
        throw "Required product file is missing: $required"
    }
}

$libPath = Join-Path $src 'lib'
if (-not (Test-Path -LiteralPath $libPath -PathType Container)) {
    throw 'Required product directory is missing: lib'
}
$runtimeFiles = @(Get-ChildItem -LiteralPath $libPath -Filter '*.ps1' -File | Sort-Object Name)
if (-not $runtimeFiles.Count) {
    throw 'No runtime PowerShell files were found in lib.'
}
foreach ($runtimeFile in $runtimeFiles) {
    $relativeFiles.Add("lib\$($runtimeFile.Name)")
}

$operationsPath = Join-Path $src 'docs\operations.md'
if (Test-Path -LiteralPath $operationsPath -PathType Leaf) {
    $relativeFiles.Add('docs\operations.md')
}

$sourceFiles = foreach ($relative in $relativeFiles | Sort-Object -Unique) {
    [pscustomobject]@{
        RelativePath = $relative
        FullName     = Join-Path $src $relative
    }
}

Write-Host "Bron: $src" -ForegroundColor DarkGray
Write-Host "`nControles:" -ForegroundColor Cyan

# These checks intentionally run over the exact product files that will be shipped.
$patterns = [ordered]@{
    'absoluut pad' = '[A-Za-z]:\\+Users\\+[^\\''"]+'
    'UPN / e-mail' = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    'tenantdomein' = '[A-Za-z0-9-]+\.onmicrosoft\.com'
    'GUID'         = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    'bearer token' = 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
}
$allow = @(
    '14d82eec-204b-4c2f-b7e8-296a70dab67e'
    '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
    'd1ddf0e4-d672-4dae-b554-9d5bdfd93547'
    '00000003-0000-0000-c000-000000000000'
    'intune-docs-studio@localhost'
    '223556219+Copilot@users.noreply.github.com'
)

$outputDirectory = [IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
}
$stage = Join-Path $outputDirectory ('.ids-build-' + [Guid]::NewGuid().ToString('N'))
$stageRoot = Join-Path $stage 'IntuneDocsStudio'

try {
    [void](New-Item -ItemType Directory -Path $stageRoot -Force)
    foreach ($file in $sourceFiles) {
        $target = Join-Path $stageRoot $file.RelativePath
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }

    $leaks = @()
    foreach ($file in $sourceFiles) {
        $extension = [IO.Path]::GetExtension($file.RelativePath)
        if ($extension -notin '.ps1', '.md', '.html', '.js', '.css', '.cmd') { continue }
        $stagedPath = Join-Path $stageRoot $file.RelativePath
        $lines = Get-Content -LiteralPath $stagedPath -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt $lines.Count; $i++) {
            foreach ($name in $patterns.Keys) {
                foreach ($match in ([regex]$patterns[$name]).Matches($lines[$i])) {
                    if ($allow -contains $match.Value) { continue }
                    if ($extension -eq '.md' -and $name -in 'absoluut pad', 'UPN / e-mail') { continue }
                    $leaks += "$($file.RelativePath):$($i + 1)  $name  ->  $($match.Value)"
                }
            }
        }
    }
    if ($leaks) {
        Write-Host '  FOUT - omgevingsspecifieke gegevens gevonden:' -ForegroundColor Red
        $leaks | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw 'Pakket niet gebouwd.'
    }
    Write-Host '  [x] geen paden, UPNs, tenant-ids of tokens in de productbestanden' -ForegroundColor Green

    $bad = @()
    foreach ($file in $sourceFiles | Where-Object { [IO.Path]::GetExtension($_.RelativePath) -eq '.ps1' }) {
        $fullPath = Join-Path $stageRoot $file.RelativePath
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count) {
            $bad += "$($file.RelativePath):$($parseErrors[0].Extent.StartLineNumber)"
        }
    }
    if ($bad) { throw "Syntaxfouten: $($bad -join ', ')" }
    Write-Host '  [x] alle meegeleverde PowerShell-bestanden parsen' -ForegroundColor Green

    . (Join-Path $stageRoot 'lib\Version.ps1')
    $sourceIdentity = Get-IdsBuildInfo -Root $stageRoot
    $buildInfo = [ordered]@{
        version = $sourceIdentity.version
        channel = $Channel
        commit  = $commit
    }
    $metadataPath = Join-Path $stageRoot 'build-info.json'
    $metadataJson = ($buildInfo | ConvertTo-Json -Compress) + [Environment]::NewLine
    [IO.File]::WriteAllText($metadataPath, $metadataJson, [Text.UTF8Encoding]::new($false))
    [void](Get-IdsBuildInfo -Root $stageRoot)

    $zipEpoch = [datetime]::SpecifyKind([datetime]::new(1980, 1, 1, 0, 0, 0), [DateTimeKind]::Local)
    foreach ($item in Get-ChildItem -LiteralPath $stageRoot -Force -Recurse |
            Sort-Object { $_.FullName.Length } -Descending) {
        if ($item.PSIsContainer) {
            [IO.Directory]::SetLastWriteTime($item.FullName, $zipEpoch)
        } else {
            [IO.File]::SetLastWriteTime($item.FullName, $zipEpoch)
        }
    }
    [IO.Directory]::SetLastWriteTime($stageRoot, $zipEpoch)
    [IO.Directory]::SetLastWriteTime($stage, $zipEpoch)

    $zip = Join-Path $outputDirectory 'IntuneDocsStudio.zip'
    Compress-Archive -Path $stageRoot -DestinationPath $zip -CompressionLevel Optimal -Force

    $size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB, 1)
    Write-Host "`nPakket klaar" -ForegroundColor Green
    Write-Host "  $zip"
    Write-Host "  $size KB, $($sourceFiles.Count + 1) bestanden"
    Write-Host "`nDelen: stuur de ZIP, of upload de map naar een repo." -ForegroundColor DarkGray
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
