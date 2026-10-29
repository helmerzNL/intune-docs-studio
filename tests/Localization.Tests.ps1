BeforeAll {
    $script:localeRepo = Split-Path -Parent $PSScriptRoot
    foreach ($module in 'Localization', 'Render', 'Export', 'BaselinePacks', 'AssessmentRules', 'AssessmentReports', 'LocalFolders', 'Assessment', 'PolicyInventory', 'PolicyApi') {
        . (Join-Path $script:localeRepo "lib\$module.ps1")
    }
    . (Join-Path $PSScriptRoot 'TestHelpers\Assessment.ps1')
    $script:localeFixture = Join-Path $script:localeRepo ('.localization-test-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $script:localeFixture 'locales'))
    foreach ($locale in Get-IdsSupportedLocales) {
        $server = @{ sample = 'Hello {name}: {count}'; onlyEnglish = 'English fallback'; numeric = '{0:N2}'; blank = 'Safe fallback' }
        if ($locale -eq 'nl-NL') { $server = @{ sample = 'Hallo {name}: {count}'; numeric = '{0:N2}'; blank = '' } }
        @{ ui = @{ fixture = 'Fixture' }; server = $server } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $script:localeFixture "locales\$locale.json") -Encoding utf8
    }
    function New-LocalizedReportResult {
        $pack = Read-IdsBaselinePack -Bytes (New-IdsTestPackBytes)
        $context = @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.26100' }; enrollmentModes = @{} }
        $snapshot = [pscustomobject]@{
            observations = @(); policies = @(); issues = @()
            sources = @([pscustomobject]@{ family = 'settingsCatalog'; platform = 'windows11'; complete = $true; errors = @() })
        }
        $evaluation = Compare-IdsAssessment -Packs @($pack) -Snapshot $snapshot -Context $context
        return [pscustomobject]@{
            schemaVersion = 1; runId = 'synthetic-localization'; generatedAt = '2026-10-29T12:00:00Z'
            tenant = @{ id = 'synthetic-tenant'; name = 'Customer name | klant' }
            context = $context; packs = @($pack); controls = $evaluation.controls; summaries = $evaluation.summaries
            policies = @(); sources = $snapshot.sources; collectionIssues = @()
        }
    }
}

AfterAll {
    Set-IdsLocale -Locale 'en-GB' -Root $script:localeRepo
    if ($script:localeFixture -and [IO.Directory]::Exists($script:localeFixture)) {
        Remove-Item -LiteralPath $script:localeFixture -Recurse -Force
    }
}

Describe 'Runspace-local server localization primitives' {
    BeforeEach { Set-IdsLocale -Locale 'en-GB' -Root $script:localeRepo }
    It 'supports exactly the ten requested canonical locale identifiers' {
        (Get-IdsSupportedLocales) -join ',' | Should -BeExactly 'en-GB,nl-NL,fr-FR,de-DE,sv-SE,es-ES,nb-NO,pt-PT,it-IT,da-DK'
        Get-IdsLocale | Should -BeExactly 'en-GB'
        Resolve-IdsLocale '' -Strict | Should -BeExactly 'en-GB'
    }

    It 'rejects noncanonical locales and path injection at strict boundaries' {
        foreach ($invalid in @('../nl-NL', '..\nl-NL', 'nl-NL.json', 'nl-nl', 'NL-NL', 'nl-NL,fr-FR', ' nl-NL', 'nn-NO', '%2e%2e', "nl-NL`n")) {
            { Resolve-IdsLocale $invalid -Strict } | Should -Throw '*locale*'
        }
    }

    It 'warns and uses English for an unsupported library locale' {
        $diagnostics = @()
        Set-IdsLocale 'not-a-locale' -WarningVariable diagnostics -WarningAction SilentlyContinue
        Get-IdsLocale | Should -BeExactly 'en-GB'
        $diagnostics -join ' ' | Should -Match 'unsupported locale'
    }

    It 'loads only allowlisted static assets' {
        foreach ($locale in Get-IdsSupportedLocales) {
            Resolve-IdsLocalizedStaticPath $script:localeRepo "/locales/$locale.json" | Should -Be (Join-Path $script:localeRepo "locales\$locale.json")
            Resolve-IdsLocalizedStaticPath $script:localeRepo "/flags/$locale.svg" | Should -Be (Join-Path $script:localeRepo "web\flags\$locale.svg")
        }
        Resolve-IdsLocalizedStaticPath $script:localeRepo '/i18n.js' | Should -Be (Join-Path $script:localeRepo 'web\i18n.js')
        foreach ($path in @('/locales/../en-GB.json', '/locales/en-GB.json/extra', '/locales/nn-NO.json', '/flags/../../private.svg',
            '/flags/nl.svg', '/flags/nl-NL.svg?x', '/flags/nl-NL.SVG', '/i18n.js/../private', '/locales/%2e%2e/en-GB.json')) {
            Resolve-IdsLocalizedStaticPath $script:localeRepo $path | Should -BeNullOrEmpty
        }
    }

    It 'interpolates values literally without evaluation or replacement-string expansion' {
        Set-IdsLocale -Locale 'nl-NL' -Root $script:localeFixture
        $value = '$1 ${env:PATH} <script> {count} | ' + "`n" + '$(throw "bad")'
        Get-IdsText sample -Arguments @{ name = $value; count = 12 } | Should -BeExactly "Hallo ${value}: 12"
    }

    It 'HTML-encodes both static text and interpolated provider content' {
        Set-IdsLocale -Locale 'nl-NL' -Root $script:localeFixture
        Get-IdsHtmlText sample -Arguments @{ name = '<script>&"'; count = 1 } |
            Should -BeExactly 'Hallo &lt;script&gt;&amp;&quot;: 1'
    }

    It 'diagnoses missing localized keys and falls back to English' {
        Set-IdsLocale -Locale 'nl-NL' -Root $script:localeFixture
        $diagnostics = @()
        Get-IdsText onlyEnglish -WarningVariable diagnostics -WarningAction SilentlyContinue | Should -BeExactly 'English fallback'
        $diagnostics -join ' ' | Should -Match 'onlyEnglish.*nl-NL'
    }

    It 'diagnoses unknown keys and missing arguments explicitly' {
        Set-IdsLocale -Locale 'nl-NL' -Root $script:localeFixture
        $diagnostics = @()
        Get-IdsText unexpected -WarningVariable diagnostics -WarningAction SilentlyContinue | Should -BeExactly '[unexpected]'
        $diagnostics.Count | Should -BeGreaterThan 0
        Get-IdsText sample -WarningAction SilentlyContinue | Should -BeExactly 'Hallo {name}: {count}'
        Get-IdsText blank -WarningAction SilentlyContinue | Should -BeExactly 'Safe fallback'
    }

    It 'supports culture-aware numeric placeholders without evaluating their arguments' {
        Set-IdsLocale -Locale nl-NL -Root $script:localeFixture
        Get-IdsText numeric -Arguments @{ '0' = 1234.5 } | Should -BeExactly '1.234,50'
    }

    It 'does not reset locale when another library is imported in the same scope' {
        Set-IdsLocale 'fr-FR'
        . (Join-Path $script:localeRepo 'lib\LocalFolders.ps1')
        Get-IdsLocale | Should -BeExactly 'fr-FR'
    }

    It 'formats presentation numbers and dates using the selected culture' {
        Format-IdsLocaleNumber 1234.5 -Format N2 -Locale de-DE | Should -BeExactly '1.234,50'
        Format-IdsLocaleDate '2026-10-29T12:34:00Z' -Locale nl-NL |
            Should -Be ([datetimeoffset]'2026-10-29T12:34:00Z').ToString('g', [Globalization.CultureInfo]::GetCultureInfo('nl-NL'))
    }
}

Describe 'Production server catalog completeness' {
    BeforeEach { Set-IdsLocale -Locale 'en-GB' -Root $script:localeRepo }
    It 'rejects copied-English placeholders except exact shared terminology reviewed per locale' {
        # These are identical native words or established technical/product labels, never prose.
        $shared = @{
            'nl-NL' = 'tenant,scripts,object,filter,filter_arg0,tag_arg0,detail,code,type,win32_app,macos_app,ios_vpp_app,managed_google_play_app,platform'
            'fr-FR' = 'tenant,version,scripts,action,sections,pages,architectures,source,code,type,technologies'
            'de-DE' = 'version,filter,name,detail,code'
            'sv-SE' = 'version,filter,filter_arg0,win32_app,macos_app,ios_vpp_app,managed_google_play_app'
            'es-ES' = 'scripts,no,general'
            'nb-NO' = 'filter,filter_arg0,operator_policy,type,win32_app,macos_app,ios_vpp_app,managed_google_play_app'
            'pt-PT' = 'scripts'
            'it-IT' = 'tenant,area,no,tag_arg0,win32_app,macos_app,ios_vpp_app,managed_google_play_app'
            'da-DK' = 'version,scripts,filter,filter_arg0,type,win32_app,macos_app,ios_vpp_app,managed_google_play_app,platform'
        }
        $english = Get-IdsLocaleCatalog 'en-GB'
        foreach ($locale in $shared.Keys) {
            $catalog = Get-IdsLocaleCatalog $locale
            $exceptions = @($shared[$locale].Split(',') | ForEach-Object { "text.$_" })
            foreach ($key in $english.Keys) {
                if ($catalog[$key] -ceq $english[$key]) {
                    $key | Should -BeIn $exceptions -Because "$locale/$key must be a real translation, not English fallback coverage"
                }
            }
            foreach ($key in $exceptions) {
                $catalog[$key] | Should -BeExactly $english[$key] -Because "$locale/$key exceptions must not grow stale"
            }
        }
    }

    It 'contains matching nonempty string keys and placeholder sets in every locale' {
        $english = (Get-Content -LiteralPath (Join-Path $script:localeRepo 'locales\en-GB.json') -Raw | ConvertFrom-Json -AsHashtable).server
        $english.Count | Should -BeGreaterThan 100
        foreach ($locale in Get-IdsSupportedLocales) {
            $catalog = (Get-Content -LiteralPath (Join-Path $script:localeRepo "locales\$locale.json") -Raw | ConvertFrom-Json -AsHashtable).server
            ($catalog.Keys | Sort-Object) -join "`n" | Should -BeExactly (($english.Keys | Sort-Object) -join "`n")
            foreach ($key in $english.Keys) {
                $catalog[$key] | Should -BeOfType string
                $catalog[$key].Trim() | Should -Not -BeNullOrEmpty
                $expected = @([regex]::Matches($english[$key], '\{(?:[A-Za-z][A-Za-z0-9_]*|\d+)(?::[^{}]+)?\}') | ForEach-Object Value | Sort-Object)
                $actual = @([regex]::Matches($catalog[$key], '\{(?:[A-Za-z][A-Za-z0-9_]*|\d+)(?::[^{}]+)?\}') | ForEach-Object Value | Sort-Object)
                $actual -join ',' | Should -BeExactly ($expected -join ',')
            }
        }
    }

    It 'has English entries for every static key referenced by production PowerShell' {
        $english = Get-IdsLocaleCatalog 'en-GB'
        foreach ($file in @((Get-ChildItem (Join-Path $script:localeRepo 'lib') -Filter *.ps1)) + @(Get-Item (Join-Path $script:localeRepo 'IntuneDocsStudio.ps1'))) {
            $tokens = $null; $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            $parseErrors.Count | Should -Be 0
            foreach ($command in $ast.FindAll({ param($n)
                $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Get-IdsText', 'Get-IdsHtmlText')
            }, $true)) {
                $elements = @($command.CommandElements)
                $keyIndex = if ($elements[1] -is [Management.Automation.Language.CommandParameterAst]) { 2 } else { 1 }
                if ($elements[$keyIndex] -is [Management.Automation.Language.StringConstantExpressionAst]) {
                    $english.Contains($elements[$keyIndex].Value) | Should -BeTrue -Because "$($file.Name) references $($elements[$keyIndex].Value)"
                }
            }

        }
    }

    It 'requires explicit catalog calls on human-facing error, progress, dialog and table surfaces' {
        $violations = @()
        foreach ($file in @((Get-ChildItem (Join-Path $script:localeRepo 'lib') -Filter *.ps1)) + @(Get-Item (Join-Path $script:localeRepo 'IntuneDocsStudio.ps1'))) {
            # Loader diagnostics and package/version validation are developer-facing.
            if ($file.Name -in @('Localization.ps1', 'Version.ps1')) { continue }
            $tokens = $null; $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            foreach ($literal in $ast.FindAll({ param($n)
                $n -is [Management.Automation.Language.StringConstantExpressionAst] -or
                $n -is [Management.Automation.Language.ExpandableStringExpressionAst]
            }, $true)) {
                if ($literal.StringConstantType -eq 'BareWord' -or $literal.Value -notmatch '\p{L}') { continue }
                $human = $literal.Value -match '\p{L}.*\s\p{L}'
                $surface = $file.Name -eq 'Export.ps1' -and $literal.Parent -is [Management.Automation.Language.HashtableAst] -and
                    $literal.Value -cmatch '^\p{Lu}'
                for ($parent = $literal.Parent; $parent; $parent = $parent.Parent) {
                    if ($parent -is [Management.Automation.Language.CommandAst]) {
                        $command = $parent.GetCommandName()
                        if ($command -in @('Get-IdsText', 'Get-IdsHtmlText')) { break }
                        if ($command -eq 'New-IdsTable' -or ($human -and $command -in @('Add-IdsWarning', 'Write-IdsLog', 'Set-IdsProgress'))) {
                            $surface = $true
                        }
                    }
                    # Graph protocol guards become invariant technical collection evidence.
                    if ($human -and $parent -is [Management.Automation.Language.ThrowStatementAst] -and
                        $file.Name -ne 'AssessmentCollection.ps1') { $surface = $true }
                    if ($human -and $parent -is [Management.Automation.Language.AssignmentStatementAst] -and
                        $parent.Left.Extent.Text -match '\.(error|phase|Description)\z') { $surface = $true }
                    if ($human -and $parent -is [Management.Automation.Language.HashtableAst]) {
                        foreach ($pair in $parent.KeyValuePairs) {
                            if ($pair.Item1.Extent.Text.Trim("'`"") -notin @('error', 'phase', 'reason')) { continue }
                            # These reasons are stable technical collection/evaluation evidence, not presentation.
                            if ($pair.Item1.Extent.Text.Trim("'`"") -eq 'reason' -and
                                $file.Name -in @('AssessmentCollection.ps1', 'AssessmentRules.ps1', 'AssessmentSettings.ps1', 'PolicySnapshots.ps1')) { continue }
                            if ($literal.Extent.StartOffset -ge $pair.Item2.Extent.StartOffset -and
                                $literal.Extent.EndOffset -le $pair.Item2.Extent.EndOffset) { $surface = $true }
                        }
                    }
                    if ($parent -is [Management.Automation.Language.StatementBlockAst] -or
                        $parent -is [Management.Automation.Language.ScriptBlockAst]) { break }
                }
                if ($surface) { $violations += "$($file.Name):$($literal.Extent.StartLineNumber): $($literal.Value)" }
            }
        }
        ($violations -join "`n") | Should -BeNullOrEmpty -Because 'app-owned prose must use explicit localization keys; machine evidence stays invariant'
    }
}

Describe 'Localized documentation and assessment presentation' {
    BeforeEach { Set-IdsLocale -Locale 'en-GB' -Root $script:localeRepo }
    It 'localizes app headings and booleans without translating customer strings or identifiers' {
        Set-IdsLocale 'nl-NL'
        $document = New-IdsDocument -Title 'Customer Policy name' -Description 'Customer description' `
            -Overview ([ordered]@{ 'Customer key' = $true }) -Assignments @() -Raw ([pscustomobject]@{ id = 'technical-id'; value = 'Enabled' })
        $document | Should -Match '## Overzicht'
        $document | Should -Match '## Toewijzingen'
        $document | Should -Match '\| Customer key \| Ja \|'
        $document | Should -Match 'Customer Policy name'
        $document | Should -Match 'Customer description'
        $document | Should -Match 'technical-id'
        $document | Should -Match '"value": "Enabled"'
    }

    It 'keeps Microsoft setting display names and configured values untouched' {
        Set-IdsLocale 'de-DE'
        $settings = @([pscustomobject]@{
            settingDefinitions = @([pscustomobject]@{ id = 'synthetic_setting'; displayName = 'Microsoft Setting DisplayName' })
            settingInstance = [pscustomobject]@{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
                settingDefinitionId = 'synthetic_setting'
                simpleSettingValue = [pscustomobject]@{ value = 'Customer configured value' }
            }
        })
        $markdown = Format-IdsSettingsCatalog $settings
        $markdown | Should -Match '\| Einstellung \| Wert \|'
        $markdown | Should -Match 'Microsoft Setting DisplayName'
        $markdown | Should -Match 'Customer configured value'
    }

    It 'supports explicit report locale without mutating caller locale or machine evidence' {
        $result = New-LocalizedReportResult
        $before = ConvertTo-Json $result -Depth 64 -Compress
        $markdown = ConvertTo-IdsAssessmentMarkdown -Result $result -Locale fr-FR
        $markdown | Should -Match '# Évaluation'
        $markdown | Should -Match 'missing \(Manquant\)'
        [Net.WebUtility]::HtmlDecode($markdown) | Should -Match 'synthetic-localization'
        $markdown | Should -Match '2026'
        (ConvertTo-Json $result -Depth 64 -Compress) | Should -BeExactly $before
        $result.controls[0].status | Should -BeExactly 'missing'
        Get-IdsLocale | Should -BeExactly 'en-GB'
    }

    It 'keeps report schema discriminators invariant in every locale, including tenant and template records' {
        $result = New-LocalizedReportResult
        $result.policies = @([pscustomobject]@{
            key = 'synthetic-policy'; id = 'synthetic-policy'; name = 'Customer policy name'
            family = 'intent'; policyType = 'intent'
            template = [pscustomobject]@{ id = 'synthetic-template'; displayName = 'Microsoft Template DisplayName' }
            assignments = @(); settingsTables = @()
        })
        $english = ConvertTo-Json (ConvertTo-IdsReportProjection $result) -Depth 64 -Compress
        foreach ($locale in Get-IdsSupportedLocales) {
            Set-IdsLocale $locale
            $projected = ConvertTo-IdsReportProjection $result
            (ConvertTo-Json $projected -Depth 64 -Compress) | Should -BeExactly $english -Because "$locale must not translate schema types or customer evidence"
            $projected.tenant.name | Should -BeExactly 'Customer name | klant'
            $projected.policies[0].template.displayName | Should -BeExactly 'Microsoft Template DisplayName'
        }
    }

    It 'projects localized display reasons without changing canonical control and policy-result contracts' {
        $result = New-LocalizedReportResult
        $control = $result.controls[0]
        $canonicalReason = $control.reason
        $control.policyResults = @([pscustomobject]@{
            policyKey = 'synthetic-policy'; status = 'missing'; reason = 'Mapped setting is absent or not configured in this policy.'
            expected = @(); observed = @()
        })
        Set-IdsLocale es-ES
        Add-IdsAssessmentEvidencePresentation -Collection @{ policies = @() } -Evaluation @{ controls = @($control) }
        Set-IdsLocale fr-FR
        $projected = ConvertTo-IdsReportProjection $result
        $projected.controls[0].reason | Should -BeExactly $canonicalReason
        $projected.controls[0].status | Should -BeExactly 'missing'
        $projected.controls[0].displayReason | Should -BeExactly (Get-IdsText 'report.reason.control_missing' -Locale es-ES)
        $projected.controls[0].policyResults[0].reason | Should -BeExactly 'Mapped setting is absent or not configured in this policy.'
        $projected.controls[0].policyResults[0].displayReason | Should -BeExactly (Get-IdsText 'report.reason.policy_missing' -Locale es-ES)
        $markdown = ConvertTo-IdsAssessmentMarkdown -Result $result -Locale es-ES
        [Net.WebUtility]::HtmlDecode($markdown) | Should -Match ([regex]::Escape($projected.controls[0].displayReason))
        Get-IdsAssessmentDisplayReason missing $canonicalReason -Locale en-GB | Should -BeExactly $canonicalReason
        Get-IdsLocale | Should -BeExactly 'fr-FR'
    }

    It 'retains distinct specific explanations for unknown OS context and incomplete collection' {
        $pack = Read-IdsBaselinePack -Bytes (New-IdsTestPackBytes)
        $pack.controls[0].applicability.osMin = '10.0.22000'
        $complete = [pscustomobject]@{
            observations = @(); policies = @(); issues = @()
            sources = @([pscustomobject]@{ family = 'settingsCatalog'; platform = 'windows11'; complete = $true; errors = @() })
        }
        $unknownContext = @{ platforms = @('windows11'); osVersions = @{}; enrollmentModes = @{} }
        $knownContext = @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.26100' }; enrollmentModes = @{} }
        $unknownOs = Compare-IdsAssessment @($pack) $complete $unknownContext
        $incomplete = Compare-IdsAssessment @($pack) ([pscustomobject]@{
            observations = @(); policies = @(); issues = @(); sources = @()
        }) $knownContext
        $unknownOs.controls[0].status | Should -BeExactly 'notAssessed'
        $incomplete.controls[0].status | Should -BeExactly 'notAssessed'
        Set-IdsLocale fr-FR
        Add-IdsAssessmentEvidencePresentation @{ policies = @() } $unknownOs
        Add-IdsAssessmentEvidencePresentation @{ policies = @() } $incomplete
        $unknownOs.controls[0].reason | Should -BeExactly 'OS version applicability (osMin) is unknown.'
        $incomplete.controls[0].reason | Should -BeExactly "Relevant source 'settingsCatalog' is incomplete or unreported."
        $unknownOs.controls[0].displayReason | Should -BeExactly (Get-IdsText 'report.reason.os_bound_unknown' -Arguments @{ bound = 'osMin' })
        $incomplete.controls[0].displayReason | Should -BeExactly (Get-IdsText 'report.reason.source_incomplete' -Arguments @{ family = 'settingsCatalog' })
        $unknownOs.controls[0].displayReason | Should -Not -BeExactly $incomplete.controls[0].displayReason
    }

    It 'localizes complete compound reasons with literal technical identities and specific assignment limitations' {
        $identity = 'deviceConfiguration:policy-$1-{bound}'
        $reason = "Policy '${identity}': OS version applicability (osMax) is unknown. Assignment evidence is incomplete; device reach is unknown."
        foreach ($locale in Get-IdsSupportedLocales) {
            $actual = Get-IdsAssessmentDisplayReason notAssessed $reason -Locale $locale -WarningAction Stop
            $expected = @(
                (Get-IdsText 'report.reason.policy_prefix' -Arguments @{ policy = $identity } -Locale $locale)
                (Get-IdsText 'report.reason.os_bound_unknown' -Arguments @{ bound = 'osMax' } -Locale $locale)
                (Get-IdsText 'report.reason.assignments_incomplete' -Locale $locale)
            ) -join ' '
            $actual | Should -BeExactly $expected
            $actual | Should -Match ([regex]::Escape($identity))
            $actual | Should -Match 'osMax'
        }
    }

    It 'diagnoses unknown external reasons without substituting customer wording or logging its contents' {
        $reason = 'Customer manual note: keep $1, {bound}, and $(throw "unsafe") verbatim.'
        $warnings = @()
        Get-IdsAssessmentDisplayReason notAssessed $reason -Locale de-DE -WarningVariable warnings -WarningAction SilentlyContinue |
            Should -BeExactly $reason
        $warnings -join ' ' | Should -Match 'unrecognized assessment reason'
        $warnings -join ' ' | Should -Not -Match 'Customer manual'
        $combined = "Selected platform context is unknown. $reason"
        Get-IdsAssessmentDisplayReason notAssessed $combined -Locale es-ES -WarningAction SilentlyContinue |
            Should -BeExactly $combined
    }

    It 'has specific translations for every app-owned evaluator sentence and template in all requested languages' {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:localeRepo 'lib\AssessmentRules.ps1'), [ref]$tokens, [ref]$parseErrors)
        $reasons = @($ast.FindAll({ param($n)
            ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or
                $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and
                ($n.Value -match '\p{L}.*\s\p{L}' -or $n.Value.StartsWith("Policy '"))
        }, $true) | ForEach-Object {
            $_.Value.Trim().Replace('$boundName', 'osMin').Replace('$family', 'settingsCatalog').
                Replace('$($policy.key)', 'deviceConfiguration:synthetic-policy').Replace('$reason', 'Configured value violates the rule.')
        } | Sort-Object -Unique)
        $reasons.Count | Should -BeGreaterThan 35
        foreach ($reason in $reasons) {
            foreach ($locale in Get-IdsSupportedLocales | Where-Object { $_ -ne 'en-GB' }) {
                $translated = Get-IdsAssessmentDisplayReason notAssessed $reason -Locale $locale -WarningAction Stop
                $translated | Should -Not -BeExactly $reason -Because "$locale must retain the specific meaning of $reason"
            }
        }
    }

    It 'returns localized validation errors while preserving English defaults' {
        { Assert-IdsAssessmentFields 'not-an-object' @() } | Should -Throw 'Assessment input must be an object.'
        Set-IdsLocale 'es-ES'
        { Assert-IdsAssessmentFields 'not-an-object' @() } | Should -Throw '*objeto*'
    }

    It 'captures folder-worker locale independently from later caller changes' {
        Set-IdsLocale 'fr-FR'
        $state = @{ FolderPicker = $null }
        try {
            Start-IdsFolderPicker -State $state -Root $script:localeRepo -Dialog { Start-Sleep -Milliseconds 150; @{ status = 'invalid' } } |
                Should -BeTrue
            Set-IdsLocale 'de-DE'
            $deadline = [datetime]::UtcNow.AddSeconds(15)
            while ($state.FolderPicker.job -and [datetime]::UtcNow -lt $deadline) {
                Sync-IdsFolderPicker $state
                Start-Sleep -Milliseconds 25
            }
            $state.FolderPicker.locale | Should -BeExactly 'fr-FR'
            $state.FolderPicker.error | Should -Match 'Impossible'
            $state.FolderPicker.error | Should -Not -Match 'konnte'
            Get-IdsLocale | Should -BeExactly 'de-DE'
        } finally { Stop-IdsFolderPicker $state }
    }
}
