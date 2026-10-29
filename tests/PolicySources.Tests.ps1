BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    foreach ($module in 'Render', 'Export', 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'BaselineArchive',
        'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi', 'PolicyInventory', 'PolicySnapshots', 'LocalFolders', 'PolicyApi', 'ReferencePacks') {
        . (Join-Path $script:root "lib\$module.ps1")
    }
    function New-TestPolicySource {
        $collection = [ordered]@{ policies = @(); sources = @(); issues = @(); documentation = @{}; documentationIssues = @() }
        foreach ($family in Get-IdsPolicyFamilies) {
            $collection.documentation[$family] = @()
            foreach ($platform in 'windows11', 'macos', 'iosIpados', 'androidEnterprise') {
                $collection.sources += @{ family = $family; platform = $platform; complete = $true; errors = @() }
            }
        }
        $raw = [pscustomobject]@{ id = 'synthetic-policy'; displayName = 'Synthetic SmartScreen'; '@odata.type' = '#microsoft.graph.windows10EndpointProtectionConfiguration'
            smartScreenEnableInShell = $true; assignments = @(@{ id = 'synthetic-assignment'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'synthetic-group' } }) }
        $collection.policies = @(@{ key = 'deviceConfiguration:synthetic-policy'; id = $raw.id; name = $raw.displayName; family = 'deviceConfiguration'
            policyType = 'windows10EndpointProtectionConfiguration'; platform = 'windows11'; rawSettings = Copy-IdsAssessmentEvidence @($raw)
            settingsComplete = $true; assignmentsComplete = $true; assignments = $raw.assignments
            template = $null; osMin = $null; osMax = $null; osApplicabilityRule = $null; unsupportedApplicability = $false; enrollmentMode = $null })
        $collection.documentation.deviceConfiguration = @(@{ policy = $raw; settings = @($raw); template = $null })
        return @{ tenant = @{ id = 'synthetic-environment'; name = 'Synthetic environment' }; capturedAt = '2026-10-29T10:00:00Z'; collection = $collection
            references = @{ groups = @{ 'synthetic-group' = 'Synthetic operators' } }; source = @{ kind = 'live'; name = 'Synthetic environment' } }
    }
    function New-TestSourceState {
        $state = @{ Auth = $null; Browser = @{}; Export = @{ running = $false; log = [Collections.ArrayList]::new() }
            Config = @{ DefaultOutputPath = (Join-Path $TestDrive 'docs'); OutputPath = (Join-Path $TestDrive 'docs')
                ImportedPackRoot = (Join-Path $TestDrive 'imports'); Port = 7654 } }
        Initialize-IdsAssessment $state
        Initialize-IdsPolicyInventory $state
        return $state
    }
    function New-TestSourceRequest {
        param($Body, [string]$Origin = 'http://localhost:7654')
        return @{ Headers = @{ Host = 'localhost:7654'; Origin = $Origin }; ContentType = 'application/json'
            ContentEncoding = [Text.Encoding]::UTF8
            InputStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))) }
    }
    function Wait-TestSourceTransfer {
        param($State)
        $deadline = [datetime]::UtcNow.AddSeconds(15)
        while ($State.PolicyTransfer.job -and [datetime]::UtcNow -lt $deadline) {
            Sync-IdsPolicyTransfer $State; Start-Sleep -Milliseconds 20
        }
        $State.PolicyTransfer.running | Should -BeFalse
        $State.PolicyTransfer.job | Should -BeNullOrEmpty
    }
}

Describe 'Explicit policy sources and portable snapshots' {
    It 'never starts collection from synchronization or a declined sign-in' {
        $state = New-TestSourceState
        $state.Auth = @{ tenant_id = 'synthetic' }
        Mock Start-IdsPolicyLoad { throw 'Unexpected collection' }
        Sync-IdsPolicyLoad $state $script:root
        $state.PolicyConsent = @{ identity = Get-IdsPolicyIdentity $state; decision = 'declined' }
        Sync-IdsPolicyLoad $state $script:root
        $state.Policies.status | Should -Be 'idle'
        (Get-IdsPolicySummary $state).consentRequired | Should -BeFalse
        Should -Invoke Start-IdsPolicyLoad -Times 0
    }

    It 'round-trips JSON folders and ZIPs with typed values, assignments, names and completeness' {
        $snapshot = New-TestPolicySource
        $export = Export-IdsPolicySnapshot $snapshot (Join-Path $TestDrive 'portable') $script:root
        $folder = Import-IdsPolicySnapshot -Path $export.path
        $folder.collection.policies[0].rawSettings[0].smartScreenEnableInShell | Should -BeOfType bool
        $folder.collection.policies[0].rawSettings[0].smartScreenEnableInShell | Should -BeTrue
        $folder.collection.policies[0].assignments[0].target.groupId | Should -Be 'synthetic-group'
        $folder.references.groups['synthetic-group'] | Should -Be 'Synthetic operators'
        $folder.capturedAt | Should -Be $snapshot.capturedAt
        $folder.source.kind | Should -Be 'offline'
        $folder.collection.sources.Count | Should -Be 20
        $zip = Join-Path $TestDrive 'portable.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($export.path, $zip)
        $uploaded = Import-IdsPolicySnapshot -Archive ([IO.File]::ReadAllBytes($zip))
        (ConvertTo-Json $uploaded.collection -Depth 64 -Compress) | Should -Be (ConvertTo-Json $folder.collection -Depth 64 -Compress)
        $before = ConvertTo-IdsAssessmentSnapshot $snapshot.collection
        $after = ConvertTo-IdsAssessmentSnapshot $uploaded.collection
        Add-IdsAssessmentPolicyPresentation $snapshot.collection $before
        Add-IdsAssessmentPolicyPresentation $uploaded.collection $after
        (ConvertTo-Json $after.policies[0].settingsTables -Depth 20 -Compress) |
            Should -BeExactly (ConvertTo-Json $before.policies[0].settingsTables -Depth 20 -Compress)
        $pack = Read-IdsBaselinePack (ConvertTo-IdsReferencePacks $snapshot).packs[0]
        $context = @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.26100' }; enrollmentModes = @{} }
        (Compare-IdsAssessment @($pack) $before $context).controls[0].status | Should -Be 'aligned'
        (Compare-IdsAssessment @($pack) $after $context).controls[0].status | Should -Be 'aligned'
        $state = New-TestSourceState
        Set-IdsActivePolicySnapshot $state $uploaded
        (Get-IdsLoadedPolicies $state).tenant.id | Should -Be 'synthetic-environment'
        $state.Auth | Should -BeNullOrEmpty
        $state.Auth = @{ tenant_id = 'different-synthetic-tenant' }
        (Get-IdsLoadedPolicies $state).tenant.id | Should -Be 'synthetic-environment'
        $state.Assessment.epoch++
        { Get-IdsLoadedPolicies $state } | Should -Throw '*import a policy set*'
    }

    It 'does not export authentication or secret policy values' {
        $snapshot = New-TestPolicySource
        $snapshot.Auth = @{ access_token = 'SYNTHETIC-CREDENTIAL-MUST-NOT-EXPORT' }
        $snapshot.collection.documentation.deviceConfiguration[0].policy | Add-Member NoteProperty wifiPreSharedKey 'SYNTHETIC-CREDENTIAL-MUST-NOT-EXPORT'
        $output = Export-IdsPolicySnapshot $snapshot (Join-Path $TestDrive 'safe') $script:root
        (Get-ChildItem -LiteralPath $output.path -Filter '*.json' -Recurse | Get-Content -Raw) -join '' | Should -Not -Match 'SYNTHETIC-CREDENTIAL-MUST-NOT-EXPORT'
    }

    It 're-exports an imported source without sign-in and preserves original provenance and incomplete evidence' {
        $original = New-TestPolicySource
        $original.collection.sources[0].complete = $false
        $firstExport = Export-IdsPolicySnapshot $original (Join-Path $TestDrive 'original') $script:root
        $firstImport = Import-IdsPolicySnapshot -Path $firstExport.path
        $state = New-TestSourceState
        Set-IdsActivePolicySnapshot $state $firstImport
        $state.Auth | Should -BeNullOrEmpty
        try {
            $request = New-TestSourceRequest @{ path = (Join-Path $TestDrive 'offline-export') }
            $response = Invoke-IdsPolicyRoute POST /api/policies/export $request $state $script:root
            $response.status | Should -Be 202
            Wait-TestSourceTransfer $state
            $state.PolicyTransfer.status | Should -Be 'completed'
            [object]::ReferenceEquals($firstImport, $state.Policies.snapshot) | Should -BeTrue
            $secondImport = Import-IdsPolicySnapshot -Path $state.PolicyTransfer.result.path
            $secondImport.source.kind | Should -Be 'offline'
            $secondImport.source.origin.kind | Should -Be 'live'
            $secondImport.source.origin.name | Should -Be $original.source.name
            $secondImport.capturedAt | Should -BeExactly $original.capturedAt
            $secondImport.tenant.name | Should -BeExactly $original.tenant.name
            $secondImport.references.groups['synthetic-group'] | Should -BeExactly 'Synthetic operators'
            $secondImport.collection.policies[0].rawSettings[0].smartScreenEnableInShell | Should -BeTrue
            $secondImport.collection.policies[0].assignments[0].target.groupId | Should -BeExactly 'synthetic-group'
            (ConvertTo-Json (Copy-IdsPolicyPayload $secondImport.collection) -Depth 64 -Compress) |
                Should -BeExactly (ConvertTo-Json (Copy-IdsPolicyPayload $firstImport.collection) -Depth 64 -Compress)
        } finally { Stop-IdsPolicyTransfer $state }
    }

    It 'rejects malformed, duplicate or unsafe input without replacing the active source' {
        $state = New-TestSourceState
        $snapshot = New-TestPolicySource; $snapshot.source.kind = 'offline'
        Set-IdsActivePolicySnapshot $state $snapshot
        $before = $state.Policies.snapshot
        $bad = Join-Path $TestDrive 'bad'; [void][IO.Directory]::CreateDirectory($bad)
        [IO.File]::WriteAllText((Join-Path $bad 'policyset.json'), '{"format":"a","format":"b"}')
        { Import-IdsPolicySnapshot -Path $bad } | Should -Throw '*duplicate*'
        [object]::ReferenceEquals($before, $state.Policies.snapshot) | Should -BeTrue
        { Assert-IdsPolicyEntryName '../outside.json' } | Should -Throw
        { Assert-IdsPolicyEntryName 'C:\outside.json' } | Should -Throw
        { Assert-IdsPolicyEntryName 'folder/NUL.json' } | Should -Throw
        $empty = Join-Path $TestDrive 'markdown-only'; [void][IO.Directory]::CreateDirectory($empty)
        [IO.File]::WriteAllText((Join-Path $empty 'README.md'), 'Synthetic')
        { Import-IdsPolicySnapshot -Path $empty } | Should -Throw '*Markdown-only*'
    }

    It 'marks legacy raw exports incomplete and does not invent a collection timestamp' {
        $legacy = Join-Path $TestDrive 'legacy'
        $raw = Join-Path $legacy '_raw\configuration\settings-catalog\synthetic.json'
        [void][IO.Directory]::CreateDirectory((Split-Path $raw))
        [IO.File]::WriteAllText($raw, '{"id":"synthetic","name":"Synthetic","platforms":"windows10"}')
        $snapshot = Import-IdsPolicySnapshot -Path $legacy
        $snapshot.collection.policies[0].settingsComplete | Should -BeFalse
        $snapshot.collection.sources.complete | Should -Not -Contain $true
        $snapshot.capturedAt | Should -BeNullOrEmpty
        $roundtrip = Export-IdsPolicySnapshot $snapshot (Join-Path $TestDrive 'legacy-roundtrip') $script:root
        $reimported = Import-IdsPolicySnapshot -Path $roundtrip.path
        $reimported.capturedAt | Should -BeNullOrEmpty
        $reimported.source.origin.format | Should -BeExactly 'legacy-raw'
    }

    It 'documents imported policies without Graph or authentication and preserves incomplete prior pages' {
        $snapshot = New-TestPolicySource
        $snapshot.source.kind = 'offline'
        function Invoke-IdsGraph { throw 'Graph must never be called offline' }
        function Invoke-IdsGraphBatch { throw 'Graph batch must never be called offline' }
        function Test-IdsGraphConnection { throw 'Auth must never be called offline' }
        $state = New-TestSourceState
        $options = @{ OutputPath = $state.Config.OutputPath; Sections = @('deviceConfigs'); IncludeRawFiles = $true; IncludeRaw = $true; GitCommit = $false; FrontMatter = $true; AdoWikiOrder = $false }
        Start-IdsExport $state $options $snapshot
        $state.Export.error | Should -BeNullOrEmpty
        $file = Get-ChildItem -LiteralPath $options.OutputPath -Recurse -Filter synthetic-smartscreen.md | Where-Object FullName -NotMatch '_raw' | Select-Object -First 1
        $file | Should -Not -BeNullOrEmpty
        $before = [IO.File]::ReadAllText($file.FullName)
        $snapshot.collection.issues += @{ family = 'deviceConfiguration'; stage = 'inventory'; reason = 'Synthetic incomplete read' }
        $snapshot.collection.documentation.deviceConfiguration[0].policy.smartScreenEnableInShell = $false
        Start-IdsExport $state $options $snapshot
        [IO.File]::ReadAllText($file.FullName) | Should -BeExactly $before
        $state.Export.summary.complete | Should -BeFalse
        $options.Sections = @('apps')
        Start-IdsExport $state $options $snapshot
        $state.Export.error | Should -Match 'Offline'
    }

    It 'creates deterministic custom reference packs and detects a differing target without policy-ID matching' {
        $source = New-TestPolicySource
        $reference = ConvertTo-IdsReferencePacks $source
        $reference.packs.Count | Should -Be 1
        $pack = Read-IdsBaselinePack $reference.packs[0]
        $pack.framework | Should -Be 'Custom reference'
        $pack.controls[0].mappings[0].expected | Should -BeTrue
        $again = ConvertTo-IdsReferencePacks $source
        (Get-IdsBuildKitSha256 $again.packs[0]) | Should -Be $pack.sha256
        $source.capturedAt = '2026-10-30T10:00:00Z'
        $newRevision = Read-IdsBaselinePack (ConvertTo-IdsReferencePacks $source).packs[0]
        $newRevision.id | Should -Not -Be $pack.id
        $newRevision.frameworkVersion | Should -Match 'Synthetic environment.*2026-10-30'
        $target = New-TestPolicySource
        $target.collection.policies[0].key = 'deviceConfiguration:other-synthetic-id'
        $target.collection.policies[0].rawSettings[0].smartScreenEnableInShell = $false
        $result = Compare-IdsAssessment @($pack) (ConvertTo-IdsAssessmentSnapshot $target.collection) @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.26100' }; enrollmentModes = @{} }
        $result.controls[0].status | Should -Be 'misaligned'
        $source.collection.policies[0].settingsComplete = $false
        $limited = ConvertTo-IdsReferencePacks $source
        $limited.packs.Count | Should -Be 0
        $limited.skippedCount | Should -BeGreaterThan 0
    }

    It 'returns selected, cancelled and failed folder results without blocking or duplicating dialogs' {
        $state = New-TestSourceState
        try {
            Start-IdsFolderPicker $state $script:root $TestDrive {
                param($Path)
                if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Native dialog requires STA' }
                Start-Sleep -Milliseconds 150
                @{ status = 'selected'; path = $Path }
            } | Should -BeTrue
            Start-IdsFolderPicker $state $script:root $TestDrive { throw 'Unexpected second dialog' } | Should -BeFalse
            $until = [datetime]::UtcNow.AddSeconds(10)
            while ($state.FolderPicker.job -and [datetime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 30; Sync-IdsFolderPicker $state }
            $state.FolderPicker.status | Should -Be 'selected'
            $state.FolderPicker.path | Should -Be $TestDrive
            Start-IdsFolderPicker $state $script:root '' { @{ status = 'cancelled' } } | Should -BeTrue
            while ($state.FolderPicker.job -and [datetime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 30; Sync-IdsFolderPicker $state }
            $state.FolderPicker.status | Should -Be 'cancelled'
            $state.FolderPicker.path | Should -BeNullOrEmpty
            Start-IdsFolderPicker $state $script:root '' { throw 'Synthetic dialog error' } | Should -BeTrue
            while ($state.FolderPicker.job -and [datetime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 30; Sync-IdsFolderPicker $state }
            $state.FolderPicker.status | Should -Be 'failed'
            $state.FolderPicker.error | Should -Match 'host'
        } finally { Stop-IdsFolderPicker $state }
    }

    It 'owns the real native dialog with a topmost form and disposes both windows' {
        $source = (Get-Command Show-IdsNativeFolderDialog).ScriptBlock
        $calls = $source.Ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'ShowDialog'
        }, $true)
        $calls.Count | Should -Be 1
        $calls[0].Arguments.Count | Should -Be 1
        $calls[0].Arguments[0].VariablePath.UserPath | Should -BeExactly 'owner'
        $source.ToString() | Should -Match '\$owner\.TopMost = \$true'
        $source.ToString() | Should -Match 'Activate\(\$owner.Handle\)'
        $source.ToString() | Should -Match '\$dialog.Dispose\(\); \$owner.Dispose\(\)'
    }

    It 'commits a validated import atomically, rejects failed replacements and invalidates dependent results' {
        $state = New-TestSourceState
        $original = New-TestPolicySource; $original.source.kind = 'offline'
        Set-IdsActivePolicySnapshot $state $original
        $state.Assessment.done = $true; $state.Assessment.result = @{ synthetic = $true }
        $export = Export-IdsPolicySnapshot (New-TestPolicySource) (Join-Path $TestDrive 'transaction') $script:root
        try {
            Start-IdsPolicyTransfer $state $script:root @{ operation = 'import'; path = $export.path } | Should -BeTrue
            [object]::ReferenceEquals($original, $state.Policies.snapshot) | Should -BeTrue
            Wait-TestSourceTransfer $state
            $state.PolicyTransfer.status | Should -Be 'completed'
            $state.Assessment.done | Should -BeFalse
            $current = $state.Policies.snapshot
            Start-IdsPolicyTransfer $state $script:root @{ operation = 'import'; path = (Join-Path $TestDrive 'does-not-exist') } | Should -BeTrue
            Wait-TestSourceTransfer $state
            $state.PolicyTransfer.status | Should -Be 'failed'
            [object]::ReferenceEquals($current, $state.Policies.snapshot) | Should -BeTrue
            Start-IdsPolicyTransfer $state $script:root @{ operation = 'import'; path = $export.path } | Should -BeTrue
            $state.Assessment.epoch++
            Wait-TestSourceTransfer $state
            $state.PolicyTransfer.status | Should -Be 'failed'
            $state.PolicyTransfer.error | Should -Match 'session changed'
            [object]::ReferenceEquals($current, $state.Policies.snapshot) | Should -BeTrue
        } finally { Stop-IdsPolicyTransfer $state }
    }

    It 'requires same-origin source mutations and explicit replacement confirmation' {
        $state = New-TestSourceState
        $snapshot = New-TestPolicySource; $snapshot.source.kind = 'offline'
        Set-IdsActivePolicySnapshot $state $snapshot
        foreach ($path in '/api/policies/import', '/api/policies/export', '/api/policies/decline', '/api/folders/picker') {
            $request = New-TestSourceRequest @{} 'https://example.invalid'
            try { (Invoke-IdsPolicyRoute POST $path $request $state $script:root).status | Should -Be 403 }
            finally { $request.InputStream.Dispose() }
        }
        $request = New-TestSourceRequest @{ path = $TestDrive }
        try { (Invoke-IdsPolicyRoute POST '/api/policies/import' $request $state $script:root).status | Should -Be 409 }
        finally { $request.InputStream.Dispose() }
        $state.PolicyTransfer = @{ running = $true }
        $request = New-TestSourceRequest @{ replace = $true; path = $TestDrive }
        try { (Invoke-IdsPolicyRoute POST '/api/policies/import' $request $state $script:root).status | Should -Be 409 }
        finally { $request.InputStream.Dispose() }
    }

    It 'removes only confirmed imported bytes and leaves bundled packs and saved reports untouched' {
        $state = New-TestSourceState
        $converted = ConvertTo-IdsReferencePacks (New-TestPolicySource)
        $imported = @(Import-IdsBaselinePackSet $converted.packs $state.Config.ImportedPackRoot)[0].pack
        $identity = "$($imported.id)@$($imported.version)#$($imported.sha256)"
        $report = Join-Path $TestDrive 'saved-report.json'
        [IO.File]::WriteAllText($report, '{"synthetic":"retained"}')
        { Remove-IdsImportedPack $state $script:root $identity $false } | Should -Throw '*Confirm*'
        $state.PolicyTransfer = @{ running = $true }
        { Remove-IdsImportedPack $state $script:root $identity $true } | Should -Throw '*Wait*'
        $state.PolicyTransfer = $null
        $bundled = @((Get-IdsAssessmentCatalog $state $script:root).packs | Where-Object origin -EQ bundled)[0]
        { Remove-IdsImportedPack $state $script:root "$($bundled.id)@$($bundled.version)#$($bundled.sha256)" $true } | Should -Throw '*bundled*'
        [IO.File]::WriteAllText((Join-Path $state.Config.ImportedPackRoot 'unrelated-invalid.json'), '{}')
        (Remove-IdsImportedPack $state $script:root $identity $true).removed | Should -Be $identity
        [IO.File]::ReadAllText($report) | Should -BeExactly '{"synthetic":"retained"}'
        @((Get-IdsAssessmentCatalog $state $script:root).packs | Where-Object id -CEQ $imported.id).Count | Should -Be 0
    }

    It 'runs the actual offline Assessment and documentation workers with throwing Graph and authentication functions' {
        $app = Join-Path $TestDrive 'offline-workers\app'
        [void][IO.Directory]::CreateDirectory((Join-Path $app 'baselines'))
        Copy-Item (Join-Path $script:root 'lib') $app -Recurse
        Add-Content (Join-Path $app 'lib\Graph.ps1') @'
function Initialize-IdsGraph { throw 'Offline Graph initialization forbidden' }
function Invoke-IdsGraph { throw 'Offline Graph read forbidden' }
function Invoke-IdsGraphRaw { throw 'Offline Graph transport forbidden' }
function Invoke-IdsGraphBatch { throw 'Offline Graph batch forbidden' }
function Test-IdsGraphConnection { throw 'Offline authentication probe forbidden' }
function Get-IdsGraphStats { throw 'Offline Graph stats forbidden' }
'@
        Add-Content (Join-Path $app 'lib\Auth.ps1') @'
function Get-IdsAccessToken { throw 'Offline authentication forbidden' }
'@
        $source = New-TestPolicySource
        $packBytes = (ConvertTo-IdsReferencePacks $source).packs[0]
        [IO.File]::WriteAllBytes((Join-Path $app 'baselines\synthetic.json'), $packBytes)
        $pack = Read-IdsBaselinePack $packBytes
        $portable = Export-IdsPolicySnapshot $source (Join-Path $TestDrive 'worker-source') $script:root
        $state = New-TestSourceState
        Set-IdsActivePolicySnapshot $state (Import-IdsPolicySnapshot -Path $portable.path)
        $options = @{ packIds = @("$($pack.id)@$($pack.version)#$($pack.sha256)")
            context = @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.26100' }; enrollmentModes = @{} }
            outputPath = (Join-Path $TestDrive 'worker-reports') }
        try {
            Start-IdsAssessmentJob $state $options $app | Should -BeTrue
            $deadline = [datetime]::UtcNow.AddSeconds(20)
            while ($state.Assessment.job -and [datetime]::UtcNow -lt $deadline) {
                Clear-IdsAssessmentJob $state; Start-Sleep -Milliseconds 30
            }
            $state.Assessment.job | Should -BeNullOrEmpty
            $state.Assessment.error | Should -BeNullOrEmpty
            $state.Assessment.done | Should -BeTrue
            $state.Assessment.result.controls[0].status | Should -Be 'aligned'
            $report = [IO.File]::ReadAllText($state.Assessment.reportPaths.markdownPath)
            $report | Should -Match 'Synthetic SmartScreen|Smart[Ss]creen'
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:root 'IntuneDocsStudio.ps1'), [ref]$tokens, [ref]$errors)
            foreach ($name in 'Start-IdsExportJob', 'Clear-IdsFinishedJob') {
                $definition = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true)
                . ([scriptblock]::Create($definition.Extent.Text))
            }
            $Root = $app
            Start-IdsExportJob @{ OutputPath = $state.Config.OutputPath; Sections = @('deviceConfigs'); GitCommit = $false } | Should -BeTrue
            while ($state.Job -and [datetime]::UtcNow -lt $deadline) {
                if ($state.Job.handle.IsCompleted) {
                    [void]$state.Job.ps.EndInvoke($state.Job.handle)
                    $state.Job.ps.Dispose(); $state.Job.runspace.Dispose(); $state.Job = $null
                } else { Start-Sleep -Milliseconds 30 }
            }
            $state.Job | Should -BeNullOrEmpty
            $state.Export.error | Should -BeNullOrEmpty
            $state.Export.done | Should -BeTrue
            $state.Export.summary.graph.requests | Should -Be 0
        } finally {
            if ($state.Job) { $state.Job.ps.Stop(); $state.Job.ps.Dispose(); $state.Job.runspace.Dispose() }
            if ($state.Assessment.job) { $state.Assessment.job.ps.Stop(); $state.Assessment.job.ps.Dispose(); $state.Assessment.job.runspace.Dispose() }
        }
    }

    It 'rejects unsafe ZIP paths, duplicate names, links, oversized entries and excessive file counts' -ForEach @(
        @{ Mode = 'traversal' }, @{ Mode = 'duplicate' }, @{ Mode = 'link' }, @{ Mode = 'large' }, @{ Mode = 'count' }
    ) {
        $stream = [IO.MemoryStream]::new()
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $names = switch ($Mode) {
                traversal { @('../policyset.json') }
                duplicate { @('policyset.json', 'POLICYSET.JSON') }
                count { @(1..501 | ForEach-Object { "$_.json" }) }
                default { @('policyset.json') }
            }
            foreach ($name in $names) {
                $entry = $zip.CreateEntry($name)
                if ($Mode -eq 'link') { $entry.ExternalAttributes = -1577123840 }
                $writer = $entry.Open()
                try {
                    $bytes = if ($Mode -eq 'large') { [byte[]]::new(10MB + 1) } else { [Text.Encoding]::UTF8.GetBytes('{}') }
                    $writer.Write($bytes, 0, $bytes.Length)
                } finally { $writer.Dispose() }
            }
        } finally { $zip.Dispose() }
        try { { Import-IdsPolicySnapshot -Archive $stream.ToArray() } | Should -Throw }
        finally { $stream.Dispose() }
    }

    It 'rejects a changed manifest hash and an unsupported schema without replacing any active source' {
        $portable = Export-IdsPolicySnapshot (New-TestPolicySource) (Join-Path $TestDrive 'schema') $script:root
        $path = Join-Path $portable.path 'policyset.json'
        $manifest = Read-IdsPolicyJson ([IO.File]::ReadAllBytes($path))
        $manifest.schemaVersion = 2L
        [IO.File]::WriteAllBytes($path, (ConvertTo-IdsBuildKitJsonBytes $manifest))
        { Import-IdsPolicySnapshot -Path $portable.path } | Should -Throw '*manifest*'
        $manifest.schemaVersion = 1L
        $manifest.files['references.json'] = '0' * 64
        [IO.File]::WriteAllBytes($path, (ConvertTo-IdsBuildKitJsonBytes $manifest))
        { Import-IdsPolicySnapshot -Path $portable.path } | Should -Throw '*SHA-256*'
    }

    It 'keeps reference identities and exact bytes deterministic across processes and source round-trips' {
        $source = New-TestPolicySource
        $expected = Get-IdsBuildKitSha256 (ConvertTo-IdsReferencePacks $source).packs[0]
        $portable = Export-IdsPolicySnapshot $source (Join-Path $TestDrive 'deterministic') $script:root
        $scriptPath = Join-Path $TestDrive 'reference-worker.ps1'
        [IO.File]::WriteAllText($scriptPath, @'
param($Root, $Path)
$ErrorActionPreference = 'Stop'
foreach ($module in 'Render', 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'BaselineArchive',
    'AssessmentReports', 'Assessment', 'PolicySnapshots', 'ReferencePacks') {
    . (Join-Path $Root "lib\$module.ps1")
}
$snapshot = Import-IdsPolicySnapshot -Path $Path
Get-IdsBuildKitSha256 (ConvertTo-IdsReferencePacks $snapshot).packs[0]
'@)
        $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        foreach ($attempt in 1..2) {
            $actual = & $pwsh -NoProfile -File $scriptPath $script:root $portable.path
            $LASTEXITCODE | Should -Be 0
            $actual | Should -BeExactly $expected
        }
    }
}
