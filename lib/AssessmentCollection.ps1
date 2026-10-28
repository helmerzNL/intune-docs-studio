<#
    Read-only assessment adapters. Graph.ps1 supplies authentication/retry/transport;
    no exporter helpers or tolerant/flattening reads are used here.

    Collection/Policy/Source/Issue use the shared assessment contract. policyType
    is the unprefixed Graph type; fixed-type endpoints supply their type when
    Graph omits it. Unknown applicability metadata remains null, never copied
    from the user's target context or treated as discovered device inventory.

    rawSettings is always an array: catalog setting wrappers (settingInstance
    and settingDefinitions), legacy/compliance policy property bags, ADMX
    definition values (definition and independently read presentationValues),
    or intent setting instances (definitionId and unchanged value/valueJson).
    Values remain typed, with null/false/zero/empty arrays distinct from absent
    members. Known secret/payload fields are null with assessmentRedacted=true
    on their containing object; normalization must treat these as unsupported,
    not as configured null. Raw settings are collection-only, not report data.

    Source.complete describes settings inventory for each selected family and
    platform. Unknown-platform/inventory failures affect every selected platform
    in that family; known-platform settings failures affect only that platform.
    Assignment-only issues never invalidate settings/source completeness.
    Issue stages are inventory, settings, assignments, and template. Group name
    lookup is intentionally omitted: group IDs and explicit unresolved labels
    are retained alongside include/exclude/filter targeting evidence.
#>

function Get-IdsAssessmentMember {
    param($Object, [string]$Name)
    if ($Object -is [Collections.IDictionary]) { return ,($Object[$Name]) }
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return ,($Object.PSObject.Properties[$Name].Value) }
    return $null
}

function Resolve-IdsAssessmentPageUri {
    param([string]$Path, [string]$Version, [string]$Resource)
    if ($Version -cnotin @('beta', 'v1.0')) { throw 'Unsupported Graph API version.' }
    $uri = $null
    if ($Path.StartsWith('/') -and -not $Path.StartsWith('//')) {
        $Path = "https://graph.microsoft.com/$Version$Path"
    }
    if (-not [uri]::TryCreate($Path, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.Host -cne 'graph.microsoft.com' -or
        $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Fragment -or
        -not $uri.AbsolutePath.StartsWith("/$Version/", [StringComparison]::Ordinal)) {
        throw 'Unsafe Graph page link.'
    }
    if ($Resource -and $uri.AbsolutePath -cne $Resource) {
        throw 'Graph page link changed resource path.'
    }
    return $uri
}

function Read-IdsAssessmentPages {
    param([string]$Path, [string]$Version = 'beta', $FirstPage, [switch]$HasFirstPage, [int]$Depth = 0)
    $items = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $next = $Path
    $resource = $null
    $count = 0
    try {
        if ($Depth -gt 32) { throw 'Expected Graph evidence nesting to stay within 32 levels.' }
        while ($null -ne $next) {
            if ($count -gt 0 -and $next -cnotmatch '\Ahttps://') { throw 'Unsafe Graph page link.' }
            $uri = Resolve-IdsAssessmentPageUri -Path $next -Version $Version -Resource $resource
            if (-not $resource) { $resource = $uri.AbsolutePath }
            if (-not $seen.Add($uri.AbsoluteUri)) { throw 'Graph pagination cycle detected.' }
            if ($count -ge 500) { throw 'Graph pagination exceeded 500 pages with a remaining next link.' }
            $page = if ($count -eq 0 -and $HasFirstPage) { $FirstPage } else {
                Invoke-IdsGraph -Path $next -Version $Version
            }
            $count++
            $values = Get-IdsAssessmentMember $page 'value'
            if ($null -eq $values -or $values -isnot [Collections.IList]) {
                throw 'Expected a Graph collection with a value array.'
            }
            foreach ($item in $values) {
                if ($null -eq $item -or ($item -isnot [pscustomobject] -and $item -isnot [Collections.IDictionary])) {
                    throw 'Expected Graph collection items to be objects.'
                }
                $items.Add($item)
                $id = [string](Get-IdsAssessmentMember $item 'id')
                $entity = if ($id -cmatch '\A[a-zA-Z0-9_-]{1,128}\z') { "$resource('$id')" } else { $null }
                Expand-IdsAssessmentNavigations -Value $item -Resource $entity -Version $Version -Errors $errors -Depth ($Depth + 1)
            }
            $next = Get-IdsAssessmentMember $page '@odata.nextLink'
            if ($null -ne $next -and ($next -isnot [string] -or [string]::IsNullOrWhiteSpace($next))) {
                throw 'Malformed Graph next link.'
            }
        }
    } catch {
        $status = Get-IdsAssessmentMember $_.Exception 'StatusCode'
        # Transport exception messages can contain response bodies or credentials.
        $reason = if ($null -ne $status) { 'Graph page request failed.' } elseif ($_.Exception.Message -match '^(Unsafe Graph|Graph page link|Graph pagination|Expected (a Graph|Graph collection)|Malformed Graph)') {
            $_.Exception.Message
        } else { 'Graph page request failed.' }
        $errors.Add([pscustomobject]@{ statusCode = $status; reason = $reason })
    }
    return [pscustomobject]@{
        items = $items.ToArray(); complete = ($errors.Count -eq 0); errors = $errors.ToArray()
    }
}

function Expand-IdsAssessmentNavigations {
    param($Value, [string]$Resource, [string]$Version, $Errors, [int]$Depth)
    if ($Depth -gt 32) {
        $Errors.Add([pscustomobject]@{ statusCode = $null; reason = 'Unsupported Graph evidence nesting beyond 32 levels.' })
        return
    }
    if ($Value -isnot [Collections.IDictionary] -and $Value -isnot [pscustomobject]) { return }
    $names = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
    foreach ($name in $names) {
        if ($name -notmatch '^(.+)@odata\.nextLink$') { continue }
        $navigation = $Matches[1]
        if (-not $Resource -or $navigation -cnotmatch '\A[a-zA-Z][a-zA-Z0-9]*\z') {
            $Errors.Add([pscustomobject]@{ statusCode = $null; reason = 'Unsupported Graph expanded collection address.' })
            continue
        }
        $navigationPath = ($Resource -creplace '^/beta/|^/v1\.0/', '/') + "/$navigation"
        $nested = Read-IdsAssessmentPages -Path $navigationPath -Version $Version -HasFirstPage -Depth ($Depth + 1) -FirstPage @{
            value = (Get-IdsAssessmentMember $Value $navigation)
            '@odata.nextLink' = (Get-IdsAssessmentMember $Value $name)
        }
        if ($Value -is [Collections.IDictionary]) {
            $Value[$navigation] = @($nested.items)
            if ($nested.complete) { $Value.Remove($name) | Out-Null }
        } else {
            $Value | Add-Member NoteProperty $navigation @($nested.items) -Force
            if ($nested.complete) { $Value.PSObject.Properties.Remove($name) }
        }
        foreach ($error in $nested.errors) { $Errors.Add($error) }
    }
    foreach ($name in $names) {
        if ($name -match '@odata\.' -or $name -cnotmatch '\A[a-zA-Z][a-zA-Z0-9]*\z') { continue }
        $child = Get-IdsAssessmentMember $Value $name
        $childResource = if ($Resource) { "$Resource/$name" } else { $null }
        if ($child -is [Collections.IList]) {
            foreach ($item in $child) {
                $id = [string](Get-IdsAssessmentMember $item 'id')
                $entity = if ($childResource -and $id -cmatch '\A[a-zA-Z0-9_-]{1,128}\z') { "$childResource('$id')" } else { $null }
                Expand-IdsAssessmentNavigations $item $entity $Version $Errors ($Depth + 1)
            }
        } else { Expand-IdsAssessmentNavigations $child $childResource $Version $Errors ($Depth + 1) }
    }
}

function Get-IdsAssessmentPages {
    param([Parameter(Mandatory)][string]$Path, [string]$Version = 'beta')
    return Read-IdsAssessmentPages -Path $Path -Version $Version
}

function Get-IdsAssessmentBatchPages {
    param([object[]]$Requests)
    $results = @{}
    try { $batch = Invoke-IdsGraphBatch -Requests $Requests -Version 'beta' } catch { $batch = @{} }
    foreach ($request in $Requests) {
        $entry = Get-IdsAssessmentMember $batch $request.id
        $status = Get-IdsAssessmentMember $entry 'status'
        if ($status -isnot [int] -or $status -lt 200 -or $status -ge 300) {
            $results[$request.id] = [pscustomobject]@{
                items = @(); complete = $false
                errors = @([pscustomobject]@{
                    statusCode = $(if ($status -is [int]) { $status } else { $null })
                    reason = $(if ($null -eq $entry) { 'Missing Graph batch entry.' } else { 'Graph batch entry did not have a successful integer status.' })
                })
            }
            continue
        }
        $results[$request.id] = Read-IdsAssessmentPages -Path $request.url -FirstPage (Get-IdsAssessmentMember $entry 'body') -HasFirstPage
    }
    return $results
}

function Add-IdsAssessmentReadIssues {
    param($Read, [string]$Family, [string]$PolicyKey, [string]$Stage, $Issues)
    foreach ($error in $Read.errors) {
        $Issues.Add([pscustomobject]@{
            family = $Family; policyKey = $PolicyKey; stage = $Stage
            statusCode = $error.statusCode; reason = $error.reason
        })
    }
}

function Get-IdsAssessmentPlatform {
    param($Policy, $Template)
    $hint = [string](Get-IdsAssessmentMember $Policy 'platforms')
    if (-not $hint) { $hint = [string](Get-IdsAssessmentMember $Policy 'platform') }
    if (-not $hint) { $hint = [string](Get-IdsAssessmentMember $Policy '@odata.type') }
    if (-not $hint -or $hint -match 'deviceManagementIntent$') {
        $hint = [string](Get-IdsAssessmentMember $Template 'platformType')
    }
    switch -Regex ($hint) {
        '^(windows10|windows11|windows10AndLater)$|^#microsoft\.graph\.windows' { return 'windows11' }
        '^(macOS)$|^#microsoft\.graph\.macOS' { return 'macos' }
        '^(iOS|iosIpados)$|^#microsoft\.graph\.ios' { return 'iosIpados' }
        '^(androidEnterprise|androidForWork)$|^#microsoft\.graph\.android(WorkProfile|DeviceOwner)' { return 'androidEnterprise' }
    }
    return $null
}

function Copy-IdsAssessmentEvidence {
    param($Value, [switch]$Secret, [int]$Depth = 0, [string[]]$SecretSettingIds = @())
    if ($Depth -gt 64) { throw 'Unsupported Graph evidence nesting depth.' }
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IList]) {
        $copy = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $copy.Add((Copy-IdsAssessmentEvidence $item -Secret:$Secret -Depth ($Depth + 1) -SecretSettingIds $SecretSettingIds)) }
        return ,($copy.ToArray())
    }
    if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $copy = [ordered]@{}
        $names = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
        $type = [string](Get-IdsAssessmentMember $Value '@odata.type')
        $secretIds = @($SecretSettingIds)
        foreach ($definition in (Get-IdsAssessmentMember $Value 'settingDefinitions')) {
            $definitionId = Get-IdsAssessmentMember $definition 'id'
            if ($definitionId -is [string] -and (Get-IdsAssessmentMember $definition 'isSecret') -eq $true) {
                $secretIds += $definitionId
            }
        }
        $secretNode = $Secret -or $type -match 'SecretSettingValue|omaSetting(Base64|Xml)' -or
            (Get-IdsAssessmentMember $Value 'isSecret') -eq $true -or (Get-IdsAssessmentMember $Value 'isEncrypted') -eq $true -or
            $secretIds -ccontains (Get-IdsAssessmentMember $Value 'settingDefinitionId')
        foreach ($name in $names) {
            if ($name -eq 'assignments') { continue }
            if ($name -match '^(password|secret|sharedSecret|preSharedKey|accessToken|refreshToken|token|privateKey|pfxCertificate|certificateContent|payload|script|scriptContent|customConfigurationXml|encryptedValue)$' -or
                ($secretNode -and $name -match '^(value|valueJson)$')) {
                $copy[$name] = $null
                $copy['assessmentRedacted'] = $true
            } else {
                $copy[$name] = Copy-IdsAssessmentEvidence (Get-IdsAssessmentMember $Value $name) -Secret:$secretNode -Depth ($Depth + 1) -SecretSettingIds $secretIds
            }
        }
        return $copy
    }
    return $Value
}

function Get-IdsAssessmentCollection {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packs, [Parameter(Mandatory)][hashtable]$Context)
    $policies = [Collections.Generic.List[object]]::new()
    $sources = [Collections.Generic.List[object]]::new()
    $issues = [Collections.Generic.List[object]]::new()
    $paths = [ordered]@{
        settingsCatalog = '/deviceManagement/configurationPolicies'
        deviceConfiguration = '/deviceManagement/deviceConfigurations'
        compliance = '/deviceManagement/deviceCompliancePolicies'
        admx = '/deviceManagement/groupPolicyConfigurations'
        intent = '/deviceManagement/intents'
    }
    foreach ($family in $paths.Keys) {
        $platforms = @($Packs | Where-Object {
            $_.platform -cin $Context.platforms -and @($_.controls.mappings.family) -ccontains $family
        } | ForEach-Object { $_.platform } | Sort-Object -Unique)
        if ($platforms.Count -eq 0) { continue }
        $issueStart = $issues.Count
        $inventory = Get-IdsAssessmentPages -Path $paths[$family]
        Add-IdsAssessmentReadIssues $inventory $family $null 'inventory' $issues
        $templates = @{}
        $policyPlatforms = @{}
        $templateRead = $null
        $seenPolicies = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($family -eq 'intent' -and $inventory.items.Count -gt 0) {
            $templateRead = Get-IdsAssessmentPages -Path '/deviceManagement/templates?$select=id,displayName,templateType,platformType'
            Add-IdsAssessmentReadIssues $templateRead $family $null 'template' $issues
            foreach ($templateItem in $templateRead.items) {
                if ($templateItem.id) { $templates[[string]$templateItem.id] = $templateItem }
            }
        }
        foreach ($raw in $inventory.items) {
            $id = [string](Get-IdsAssessmentMember $raw 'id')
            if ($id -cnotmatch '\A[a-zA-Z0-9_-]{1,128}\z') {
                $issues.Add([pscustomobject]@{ family = $family; policyKey = $null; stage = 'inventory'; statusCode = $null; reason = 'Missing or unsafe Graph policy ID.' })
                continue
            }
            $key = "${family}:$id"
            if (-not $seenPolicies.Add($id)) {
                $issues.Add([pscustomobject]@{ family = $family; policyKey = $key; stage = 'inventory'; statusCode = $null; reason = 'Duplicate Graph policy identity.' })
                continue
            }
            $base = "$($paths[$family])('$id')"
            if ($family -eq 'intent') { $base = "$($paths[$family])/$id" }
            $requests = @(@{ id = 'assignments'; url = "$base/assignments" })
            switch ($family) {
                settingsCatalog { $requests += @{ id = 'settings'; url = "$base/settings?`$expand=settingDefinitions&`$top=1000" } }
                admx { $requests += @{ id = 'settings'; url = "$base/definitionValues?`$expand=definition" } }
                intent { $requests += @{ id = 'settings'; url = "$base/settings" } }
            }
            $reads = Get-IdsAssessmentBatchPages $requests
            $settings = if ($family -in @('deviceConfiguration', 'compliance')) {
                [pscustomobject]@{ items = @($raw); complete = $true; errors = @() }
            } else { $reads.settings }
            $assignments = $reads.assignments
            Add-IdsAssessmentReadIssues $settings $family $key 'settings' $issues
            Add-IdsAssessmentReadIssues $assignments $family $key 'assignments' $issues
            if ($family -eq 'admx') {
                $presentationRequests = [Collections.Generic.List[object]]::new()
                $seenDefinitions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($definition in $settings.items) {
                    $definitionId = [string](Get-IdsAssessmentMember $definition 'id')
                    if ($definitionId -cnotmatch '\A[a-zA-Z0-9_-]{1,128}\z' -or -not $seenDefinitions.Add($definitionId)) {
                        $settings.complete = $false
                        $issues.Add([pscustomobject]@{ family = $family; policyKey = $key; stage = 'settings'; statusCode = $null; reason = 'Missing, duplicate, or unsafe ADMX definition-value ID.' })
                        continue
                    }
                    $presentationRequests.Add(@{
                        id = $definitionId; url = "$base/definitionValues('$definitionId')/presentationValues?`$expand=presentation"
                    })
                }
                $presentations = if ($presentationRequests.Count -gt 0) { Get-IdsAssessmentBatchPages $presentationRequests.ToArray() } else { @{} }
                foreach ($definition in $settings.items) {
                    $definitionId = [string](Get-IdsAssessmentMember $definition 'id')
                    if (-not $presentations.ContainsKey($definitionId)) { continue }
                    $presentation = $presentations[$definitionId]
                    Add-IdsAssessmentReadIssues $presentation $family $key 'settings' $issues
                    if (-not $presentation.complete) { $settings.complete = $false }
                    if ($definition -is [Collections.IDictionary]) { $definition['presentationValues'] = @($presentation.items) }
                    else { $definition | Add-Member NoteProperty presentationValues @($presentation.items) -Force }
                }
            }
            foreach ($setting in $settings.items) {
                $identity = switch ($family) {
                    settingsCatalog { Get-IdsAssessmentMember (Get-IdsAssessmentMember $setting 'settingInstance') 'settingDefinitionId' }
                    admx { Get-IdsAssessmentMember (Get-IdsAssessmentMember $setting 'definition') 'id' }
                    intent { Get-IdsAssessmentMember $setting 'definitionId' }
                    default { $id }
                }
                if ($identity -isnot [string] -or [string]::IsNullOrWhiteSpace($identity)) {
                    $settings.complete = $false
                    $issues.Add([pscustomobject]@{ family = $family; policyKey = $key; stage = 'settings'; statusCode = $null; reason = 'Unsupported Graph setting shape without a stable setting identity.' })
                }
            }
            foreach ($assignment in $assignments.items) {
                $target = Get-IdsAssessmentMember $assignment 'target'
                $targetType = Get-IdsAssessmentMember $target '@odata.type'
                if ($targetType -isnot [string] -or [string]::IsNullOrWhiteSpace($targetType) -or
                    ($targetType -match 'GroupAssignmentTarget$' -and -not (Get-IdsAssessmentMember $target 'groupId'))) {
                    $assignments.complete = $false
                    $issues.Add([pscustomobject]@{ family = $family; policyKey = $key; stage = 'assignments'; statusCode = $null; reason = 'Unsupported Graph assignment target shape.' })
                }
                $groupId = Get-IdsAssessmentMember $target 'groupId'
                if ($groupId) {
                    if ($target -is [Collections.IDictionary]) { $target['groupDisplayName'] = "Unresolved group ($groupId)" }
                    else { $target | Add-Member NoteProperty groupDisplayName "Unresolved group ($groupId)" -Force }
                }
            }
            $name = Get-IdsAssessmentMember $raw 'name'
            if (-not $name) { $name = Get-IdsAssessmentMember $raw 'displayName' }
            if (-not $name) { $name = $id }
            $template = Get-IdsAssessmentMember $raw 'templateReference'
            if ($family -eq 'intent') {
                $templateId = [string](Get-IdsAssessmentMember $raw 'templateId')
                $template = if ($templateId -and $templates.ContainsKey($templateId)) { $templates[$templateId] } else { @{ id = $templateId } }
                if (-not $templateRead.complete -or -not $templateId -or -not $templates.ContainsKey($templateId)) {
                    $settings.complete = $false
                    $issues.Add([pscustomobject]@{ family = $family; policyKey = $key; stage = 'template'; statusCode = $null; reason = 'Intent template metadata is incomplete or unresolved.' })
                }
            }
            $type = ([string](Get-IdsAssessmentMember $raw '@odata.type')) -creplace '^#microsoft\.graph\.', ''
            if (-not $type) {
                $type = switch ($family) {
                    settingsCatalog { 'deviceManagementConfigurationPolicy' }
                    admx { 'groupPolicyConfiguration' }
                    intent { 'deviceManagementIntent' }
                    default { $null }
                }
            }
            if (-not $type) {
                $settings.complete = $false
                $issues.Add([pscustomobject]@{ family = $family; policyKey = $key; stage = 'settings'; statusCode = $null; reason = 'Missing Graph policy type for property-based evidence.' })
            }
            $platform = Get-IdsAssessmentPlatform $raw $template
            if ($family -eq 'admx') { $platform = 'windows11' }
            $policyPlatforms[$key] = $platform
            $safeSettings = @()
            try { $safeSettings = Copy-IdsAssessmentEvidence @($settings.items) } catch {
                $settings.complete = $false
                $issues.Add([pscustomobject]@{ family = $family; policyKey = $key; stage = 'settings'; statusCode = $null; reason = 'Unsupported Graph settings evidence nesting.' })
            }
            $policies.Add([pscustomobject]@{
                key = $key; id = $id; name = $name; family = $family; policyType = $type; template = $template
                platform = $platform
                osMin = (Get-IdsAssessmentMember $raw 'osMinimumVersion')
                osMax = (Get-IdsAssessmentMember $raw 'osMaximumVersion')
                enrollmentMode = (Get-IdsAssessmentMember $raw 'enrollmentMode')
                rawSettings = $safeSettings; assignments = @($assignments.items)
                settingsComplete = $settings.complete; assignmentsComplete = $assignments.complete
            })
        }
        foreach ($platform in $platforms) {
            $sourceErrors = @($issues | Select-Object -Skip $issueStart | Where-Object {
                $_.stage -ne 'assignments' -and
                (-not $_.policyKey -or -not $policyPlatforms[$_.policyKey] -or $policyPlatforms[$_.policyKey] -eq $platform)
            })
            $sources.Add([pscustomobject]@{ family = $family; platform = $platform; complete = ($sourceErrors.Count -eq 0); errors = $sourceErrors })
        }
    }
    return [pscustomobject]@{ policies = $policies.ToArray(); sources = $sources.ToArray(); issues = $issues.ToArray() }
}
