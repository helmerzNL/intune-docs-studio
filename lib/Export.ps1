<#
    Export.ps1 — collects Intune configuration and writes a Git-friendly Markdown tree.

    Design notes
      * Idempotent: files are only rewritten when their content actually changes.
      * Self-pruning: a manifest records every file written, so objects deleted in Intune
        disappear from the repository on the next run instead of lingering forever.
      * Batched: assignment/settings/detail lookups go through Graph $batch (20 per call).
#>

# --- File helpers -----------------------------------------------------------------------

$script:IdsUtf8 = New-Object Text.UTF8Encoding($false)

function Write-IdsFile {
    <#  Writes UTF-8 (no BOM) with LF endings, skipping the write when nothing changed.
        Returns 'created' | 'updated' | 'unchanged'. #>
    param([string]$Path, [string]$Content)
    $normalised = $Content -replace "`r`n", "`n"
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $Path) {
        try {
            $existing = [IO.File]::ReadAllText($Path, $script:IdsUtf8)
            if ($existing -eq $normalised) { return 'unchanged' }
        } catch { }
        [IO.File]::WriteAllText($Path, $normalised, $script:IdsUtf8)
        return 'updated'
    }
    [IO.File]::WriteAllText($Path, $normalised, $script:IdsUtf8)
    return 'created'
}

function New-IdsContext {
    <#  Mutable state carried through the whole export run. #>
    param([string]$Root, [hashtable]$Options, $State)
    return @{
        Root       = $Root
        Options    = $Options
        State      = $State
        TenantId   = ''
        TenantName = ''
        Written    = New-Object System.Collections.Generic.HashSet[string]
        Stats      = @{ created = 0; updated = 0; unchanged = 0; deleted = 0 }
        Counts     = [ordered]@{}
        Index      = [ordered]@{}   # section key -> array of @{ title; path }
        Assign     = New-Object System.Collections.ArrayList
        Warnings   = New-Object System.Collections.ArrayList
        UsedPaths  = @{}
    }
}

function Add-IdsWarning {
    param($Ctx, [string]$Message)
    [void]$Ctx.Warnings.Add($Message)
    Write-IdsLog -State $Ctx.State -Message $Message -Level 'warn'
}

function Write-IdsLog {
    param($State, [string]$Message, [string]$Level = 'info')
    if ($State -and $State.Export -and $State.Export.log) {
        [void]$State.Export.log.Add(@{
                time    = (Get-Date).ToString('HH:mm:ss')
                level   = $Level
                message = $Message
            })
        while ($State.Export.log.Count -gt 600) { $State.Export.log.RemoveAt(0) }
    }
    if ($Level -eq 'warn') { Write-Host "  ! $Message" -ForegroundColor DarkYellow }
    elseif ($Level -eq 'error') { Write-Host "  x $Message" -ForegroundColor Red }
    else { Write-Host "  $Message" }
}

function Set-IdsProgress {
    param($State, [int]$Percent, [string]$Phase)
    if (-not $State -or -not $State.Export) { return }
    if ($Percent -ge 0) { $State.Export.percent = [Math]::Min(100, $Percent) }
    if ($Phase) { $State.Export.phase = $Phase }
}

function Resolve-IdsDocPath {
    <#  Allocates a unique relative path for an object, disambiguating duplicate display
        names with a short id fragment rather than overwriting. #>
    param($Ctx, [string]$Folder, [string]$Name, [string]$Id)
    $slug = New-IdsSlug -Text $Name
    $rel = "$Folder/$slug.md"
    if ($Ctx.UsedPaths.ContainsKey($rel.ToLowerInvariant())) {
        $rel = "$Folder/$slug-$(Get-IdsShortId $Id).md"
    }
    $Ctx.UsedPaths[$rel.ToLowerInvariant()] = $true
    return $rel
}

function Save-IdsDoc {
    <#  Writes one object page plus (optionally) its raw JSON sidecar, and records it for the
        index, the assignment reports and the prune manifest. #>
    param($Ctx, [string]$Section, [string]$Folder, [string]$Title, [string]$Markdown,
        [string]$Id, $RawObject, $Assignments)

    $rel = Resolve-IdsDocPath -Ctx $Ctx -Folder $Folder -Name $Title -Id $Id
    $full = Join-Path $Ctx.Root ($rel -replace '/', '\')
    if ($Ctx.PreservePolicyPages) {
        if ([IO.File]::Exists($full)) {
            $Markdown = [IO.File]::ReadAllText($full)
            $RawObject = $null
        } else {
            $Markdown = '> Offline evidence is incomplete. Missing settings, assignments and reference names are unknown, not an empty or compliant configuration.' + "`n`n" +
                ($Markdown -replace '_No (?:ADMX )?settings configured\._', '_Settings are unavailable in this export; completeness is unknown._')
        }
    }
    $result = Write-IdsFile -Path $full -Content $Markdown
    $Ctx.Stats[$result]++
    [void]$Ctx.Written.Add($rel)

    if (-not $Ctx.Index.Contains($Section)) { $Ctx.Index[$Section] = New-Object System.Collections.ArrayList }
    [void]$Ctx.Index[$Section].Add(@{ title = $Title; path = $rel })

    if ($Ctx.Options.IncludeRawFiles -and $RawObject) {
        $rawRel = "_raw/$Folder/$([IO.Path]::GetFileNameWithoutExtension($rel)).json"
        $rawFull = Join-Path $Ctx.Root ($rawRel -replace '/', '\')
        $r2 = Write-IdsFile -Path $rawFull -Content (ConvertTo-IdsJson -InputObject $RawObject)
        $Ctx.Stats[$r2]++
        [void]$Ctx.Written.Add($rawRel)
    }

    $rows = @(ConvertTo-IdsAssignmentRows -Assignments $Assignments)
    foreach ($row in $rows) {
        [void]$Ctx.Assign.Add([pscustomobject]@{
                Section    = $Section
                Object     = $Title
                Path       = $rel
                Mode       = $row.Mode
                Group      = $row.Group
                GroupId    = $row.GroupId
                Filter     = $row.Filter
                FilterId   = $row.FilterId
                FilterMode = $row.FilterMode
                Intent     = $row.Intent
            })
    }
    if ($rows.Count -eq 0 -and $null -ne $Assignments) {
        [void]$Ctx.Assign.Add([pscustomobject]@{
                Section = $Section; Object = $Title; Path = $rel
                Mode = 'Unassigned'; Group = ''; GroupId = $null
                Filter = $null; FilterId = $null; FilterMode = $null; Intent = $null
            })
    }
    return $rel
}

# --- Lookup collection ------------------------------------------------------------------

function Initialize-IdsLookups {
    param($Ctx)
    if ($Ctx.PolicySnapshot.source.kind -eq 'offline') {
        $refs = $Ctx.PolicySnapshot.references
        Set-IdsLookupMaps -Groups $refs.groups -Filters $refs.filters -ScopeTags $refs.scopeTags -Categories $refs.categories
        Set-IdsGroupResolver { param($Id) return "(reference name unavailable in offline set: $Id)" }
        $Ctx.Filters = @{}; $Ctx.Categories = @{}; $Ctx.GroupObjects = @{}; $Ctx.GroupErrors = @{}
        return
    }
    Set-IdsProgress -State $Ctx.State -Percent 3 -Phase 'Loading reference data'

    $categories = @{}
    try {
        $cats = Invoke-IdsGraph -Path '/deviceManagement/configurationCategories?$select=id,displayName,parentCategoryId' -All -Tolerant
        foreach ($c in @($cats)) { if ($c -and $c.id) { $categories[$c.id] = $c } }
        Write-IdsLog -State $Ctx.State -Message "Loaded $($categories.Count) settings-catalog categories"
    } catch { Add-IdsWarning $Ctx "Could not load settings catalog categories: $($_.Exception.Message)" }

    $filters = @{}
    try {
        # The rule is the point of a filter, so fetch it here rather than only the name:
        # assignments render the expression inline.
        $f = Invoke-IdsGraph -Path '/deviceManagement/assignmentFilters?$select=id,displayName,rule,platform,assignmentFilterManagementType' -All -Tolerant
        foreach ($x in @($f)) { if ($x -and $x.id) { $filters[$x.id] = $x } }
    } catch { Add-IdsWarning $Ctx "Could not load assignment filters: $($_.Exception.Message)" }

    $tags = @{}
    try {
        $t = Invoke-IdsGraph -Path '/deviceManagement/roleScopeTags?$select=id,displayName' -All -Tolerant
        foreach ($x in @($t)) { if ($x -and $x.id) { $tags[[string]$x.id] = $x.displayName } }
    } catch { Add-IdsWarning $Ctx "Could not load scope tags: $($_.Exception.Message)" }

    Set-IdsLookupMaps -Groups @{} -Filters $filters -ScopeTags $tags -Categories $categories
    $Ctx.Filters = $filters
    $Ctx.Categories = $categories

    # Lazy group resolution: only groups actually referenced by an assignment are fetched,
    # and the full object is retained so the groups section can be written later.
    $Ctx.GroupObjects = @{}
    $Ctx.GroupErrors = @{}
    $store = $Ctx.GroupObjects
    $errors = $Ctx.GroupErrors
    Set-IdsGroupResolver -Resolver {
        param($Id)
        $select = '?$select=id,displayName,description,groupTypes,membershipRule,securityEnabled,mailEnabled'
        try {
            $g = Invoke-IdsGraph -Path ("/groups/$Id" + $select) -Version 'v1.0'
            if ($g -and $g.displayName) {
                $store[$Id] = $g
                return $g.displayName
            }
            return $null
        } catch {
            # Distinguish a genuinely deleted group from one we simply may not read: the
            # difference matters a great deal when reviewing the documentation.
            $status = 0
            if ($_.Exception.PSObject.Properties['StatusCode']) { $status = [int]$_.Exception.StatusCode }
            $errors[$Id] = $status
            switch ($status) {
                404 { return "(deleted group $Id)" }
                403 { return "(group $Id — insufficient permission to read)" }
                default { return "(unresolved group $Id)" }
            }
        }
    }.GetNewClosure()
}

function Resolve-IdsGroupNames {
    <#  Resolves only the groups actually referenced by assignments — far cheaper than
        enumerating every group in the directory. #>
    param($Ctx, [string[]]$GroupIds)
    $unique = @($GroupIds | Where-Object { $_ } | Select-Object -Unique)
    if ($unique.Count -eq 0) { return @{} }
    $map = @{}
    $requests = @()
    $i = 0
    foreach ($g in $unique) {
        $i++
        $requests += @{ id = "g$i"; url = "/groups/$g" + '?$select=id,displayName,description,groupTypes,membershipRule,securityEnabled,mailEnabled' }
    }
    $res = Invoke-IdsGraphBatch -Requests $requests
    $i = 0
    foreach ($g in $unique) {
        $i++
        $entry = $res["g$i"]
        if ($entry -and $entry.status -eq 200 -and $entry.body) {
            $map[$g] = $entry.body
        }
    }
    return $map
}

# --- Section collectors -----------------------------------------------------------------

function Get-IdsExportPolicyDocuments {
    param($Ctx, [string]$Family)
    $Ctx.PreservePolicyPages = $false
    $collection = $Ctx.PolicySnapshot.collection
    if (-not $collection.documentation.ContainsKey($Family)) { throw 'Loaded policy family is unavailable. Reload policies.' }
    if (@($collection.issues + $collection.documentationIssues | Where-Object family -EQ $Family).Count -or
        @($collection.sources | Where-Object { $_.family -eq $Family -and -not $_.complete }).Count -or
        @($collection.policies | Where-Object { $_.family -eq $Family -and -not $_.settingsComplete }).Count) {
        if ($Ctx.PolicySnapshot.source.kind -eq 'offline') {
            $Ctx.OfflineIncomplete = $true
            $Ctx.PreservePolicyPages = $true
            Add-IdsWarning $Ctx "$Family has incomplete offline evidence. Existing policy pages are preserved; new pages explicitly show the limitation."
            return $collection.documentation[$Family]
        }
        # A partial inventory must never erase previously generated policy pages.
        throw 'Loaded policy evidence is incomplete for this family. Reload policies after resolving the collection warnings.'
    }
    return $collection.documentation[$Family]
}

function Export-IdsSettingsCatalog {
    param($Ctx)
    $documents = @()
    $policies = if ($Ctx.PolicySnapshot) {
        $documents = @(Get-IdsExportPolicyDocuments $Ctx 'settingsCatalog')
        @($documents | ForEach-Object policy)
    } else { Invoke-IdsGraph -Path '/deviceManagement/configurationPolicies?$expand=assignments' -All -Tolerant }
    if (-not $policies) { return 0 }
    $policies = @($policies)

    # Pull every policy's settings (with inline definitions) in batches of 20.
    $settingsById = @{}
    if ($Ctx.PolicySnapshot) {
        foreach ($document in $documents) { $settingsById[$document.policy.id] = $document.settings }
    } else {
    for ($i = 0; $i -lt $policies.Count; $i += 20) {
        $slice = $policies[$i..([Math]::Min($i + 19, $policies.Count - 1))]
        $reqs = @()
        foreach ($p in $slice) {
            $reqs += @{ id = $p.id; url = "/deviceManagement/configurationPolicies('$($p.id)')/settings?`$expand=settingDefinitions&`$top=1000" }
        }
        $res = Invoke-IdsGraphBatch -Requests $reqs
        foreach ($p in $slice) { $settingsById[$p.id] = Get-IdsBatchValues $res[$p.id] }
    }
    }

    foreach ($p in ($policies | Sort-Object name)) {
        $name = $p.name
        if (-not $name) { $name = $p.id }
        $platform = [string]$p.platforms
        $technologies = [string]$p.technologies
        $folder = 'configuration/settings-catalog'
        if ($technologies -match 'mdm|windows10XManagement|configManager' -and $platform) {
            $folder = 'configuration/settings-catalog/' + (New-IdsSlug ($platform -replace ',.*$', ''))
        }
        $settings = $settingsById[$p.id]

        $md = New-IdsDocument `
            -Title $name `
            -Description $p.description `
            -FrontMatter ([ordered]@{
                intuneId = $p.id; objectType = 'settingsCatalogPolicy'
                platform = $platform; technologies = $technologies
                lastModified = (Format-IdsDate $p.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                'Policy type'  = 'Settings catalog'
                'Platform'     = $platform
                'Technologies' = $technologies
                'Created'      = (Format-IdsDate $p.createdDateTime)
                'Last modified' = (Format-IdsDate $p.lastModifiedDateTime)
                'Scope tags'   = (Format-IdsScopeTags $p.roleScopeTagIds)
                'Setting count' = $p.settingCount
                'Intune id'    = $p.id
            }) `
            -Sections ([ordered]@{ 'Settings' = (Format-IdsSettingsCatalog -Settings $settings) }) `
            -Assignments $p.assignments `
            -Raw $p

        Save-IdsDoc -Ctx $Ctx -Section 'Settings catalog' -Folder $folder -Title $name `
            -Markdown $md -Id $p.id -RawObject $p -Assignments $p.assignments | Out-Null
    }
    return $policies.Count
}

function Export-IdsDeviceConfigurations {
    param($Ctx)
    $items = if ($Ctx.PolicySnapshot) {
        @(Get-IdsExportPolicyDocuments $Ctx 'deviceConfiguration' | ForEach-Object policy)
    } else { Invoke-IdsGraph -Path '/deviceManagement/deviceConfigurations?$expand=assignments' -All -Tolerant }
    if (-not $items) { return 0 }
    $items = @($items)
    foreach ($c in ($items | Sort-Object displayName)) {
        $type = [string]$c.'@odata.type'
        $isCustom = $type -match 'CustomConfiguration'
        $folder = 'configuration/templates'
        if ($isCustom) { $folder = 'configuration/custom' }

        $sections = [ordered]@{}
        if ($isCustom -and $c.PSObject.Properties['omaSettings']) {
            $sections['OMA-URI settings'] = (Format-IdsOmaSettings -OmaSettings $c.omaSettings)
        }
        if ($isCustom -and $c.PSObject.Properties['payload'] -and $c.payload) {
            if ($Ctx.Options.IncludeScriptContent) {
                $sections['Payload'] = "``````xml`n" + (ConvertFrom-IdsBase64 ([string]$c.payload)) + "`n``````"
            } else {
                $sections['Payload'] = '_Payload omitted (script and payload content disabled for this export)._'
            }
        }
        $sections['Settings'] = (Format-IdsTemplateSettings -Config $c)

        $md = New-IdsDocument `
            -Title $c.displayName -Description $c.description `
            -FrontMatter ([ordered]@{
                intuneId = $c.id; objectType = ($type -replace '#microsoft\.graph\.', '')
                lastModified = (Format-IdsDate $c.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                'Profile type'  = (Format-IdsOdataType $type)
                'Created'       = (Format-IdsDate $c.createdDateTime)
                'Last modified' = (Format-IdsDate $c.lastModifiedDateTime)
                'Version'       = $c.version
                'Scope tags'    = (Format-IdsScopeTags $c.roleScopeTagIds)
                'Intune id'     = $c.id
            }) `
            -Sections $sections -Assignments $c.assignments -Raw $c

        $label = 'Configuration profiles'
        if ($isCustom) { $label = 'Custom profiles' }
        Save-IdsDoc -Ctx $Ctx -Section $label -Folder $folder -Title $c.displayName `
            -Markdown $md -Id $c.id -RawObject $c -Assignments $c.assignments | Out-Null
    }
    return $items.Count
}

function Export-IdsAdministrativeTemplates {
    param($Ctx)
    $settingsById = @{}
    $items = if ($Ctx.PolicySnapshot) {
        foreach ($document in @(Get-IdsExportPolicyDocuments $Ctx 'admx')) {
            $settingsById[$document.policy.id] = $document.settings
            $document.policy
        }
    } else { Invoke-IdsGraph -Path '/deviceManagement/groupPolicyConfigurations?$expand=assignments' -All -Tolerant }
    if (-not $items) { return 0 }
    $items = @($items)
    foreach ($g in ($items | Sort-Object displayName)) {
        $defValues = @()
        if ($Ctx.PolicySnapshot) { $defValues = @($settingsById[$g.id]) } else {
        try {
            $defValues = @(Invoke-IdsGraph -Path "/deviceManagement/groupPolicyConfigurations('$($g.id)')/definitionValues?`$expand=definition" -All -Tolerant)
            $reqs = @()
            foreach ($d in $defValues) {
                $reqs += @{ id = $d.id; url = "/deviceManagement/groupPolicyConfigurations('$($g.id)')/definitionValues('$($d.id)')/presentationValues?`$expand=presentation" }
            }
            if ($reqs.Count -gt 0) {
                $res = Invoke-IdsGraphBatch -Requests $reqs
                foreach ($d in $defValues) {
                    $pv = Get-IdsBatchValues $res[$d.id]
                    $d | Add-Member -NotePropertyName presentationValues -NotePropertyValue $pv -Force
                }
            }
        } catch { Add-IdsWarning $Ctx "ADMX values for '$($g.displayName)': $($_.Exception.Message)" }
        }

        $md = New-IdsDocument `
            -Title $g.displayName -Description $g.description `
            -FrontMatter ([ordered]@{
                intuneId = $g.id; objectType = 'groupPolicyConfiguration'
                lastModified = (Format-IdsDate $g.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                'Profile type'  = 'Administrative template (ADMX)'
                'Created'       = (Format-IdsDate $g.createdDateTime)
                'Last modified' = (Format-IdsDate $g.lastModifiedDateTime)
                'Configured settings' = @($defValues).Count
                'Scope tags'    = (Format-IdsScopeTags $g.roleScopeTagIds)
                'Intune id'     = $g.id
            }) `
            -Sections ([ordered]@{ 'Settings' = (Format-IdsAdmxSettings -DefinitionValues $defValues) }) `
            -Assignments $g.assignments -Raw $g

        Save-IdsDoc -Ctx $Ctx -Section 'Administrative templates' -Folder 'configuration/administrative-templates' `
            -Title $g.displayName -Markdown $md -Id $g.id -RawObject $g -Assignments $g.assignments | Out-Null
    }
    return $items.Count
}

function Export-IdsCompliance {
    param($Ctx)
    if ($Ctx.PolicySnapshot) {
        $items = @(Get-IdsExportPolicyDocuments $Ctx 'compliance' | ForEach-Object policy)
    } else {
    $path = '/deviceManagement/deviceCompliancePolicies?$expand=assignments,scheduledActionsForRule($expand=scheduledActionConfigurations)'
    $items = Invoke-IdsGraph -Path $path -All -Tolerant
    if (-not $items) {
        $items = Invoke-IdsGraph -Path '/deviceManagement/deviceCompliancePolicies?$expand=assignments' -All -Tolerant
    }
    }
    if (-not $items) { return 0 }
    $items = @($items)
    foreach ($c in ($items | Sort-Object displayName)) {
        $platform = 'other'
        $t = [string]$c.'@odata.type'
        if ($t -match 'windows')  { $platform = 'windows' }
        elseif ($t -match 'ios')  { $platform = 'ios' }
        elseif ($t -match 'macOS') { $platform = 'macos' }
        elseif ($t -match 'android') { $platform = 'android' }
        elseif ($t -match 'aosp') { $platform = 'android' }

        $sections = [ordered]@{
            'Compliance settings' = (Format-IdsTemplateSettings -Config $c)
            'Actions for noncompliance' = (Format-IdsComplianceActions -ScheduledActions $c.scheduledActionsForRule)
        }
        $md = New-IdsDocument `
            -Title $c.displayName -Description $c.description `
            -FrontMatter ([ordered]@{
                intuneId = $c.id; objectType = ($t -replace '#microsoft\.graph\.', '')
                platform = $platform; lastModified = (Format-IdsDate $c.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                'Policy type'   = (Format-IdsOdataType $t)
                'Platform'      = $platform
                'Created'       = (Format-IdsDate $c.createdDateTime)
                'Last modified' = (Format-IdsDate $c.lastModifiedDateTime)
                'Version'       = $c.version
                'Scope tags'    = (Format-IdsScopeTags $c.roleScopeTagIds)
                'Intune id'     = $c.id
            }) `
            -Sections $sections -Assignments $c.assignments -Raw $c

        Save-IdsDoc -Ctx $Ctx -Section 'Compliance policies' -Folder "compliance/$platform" `
            -Title $c.displayName -Markdown $md -Id $c.id -RawObject $c -Assignments $c.assignments | Out-Null
    }
    return $items.Count
}

function Export-IdsEndpointSecurity {
    param($Ctx)
    $templates = @{}
    $settingsById = @{}
    $items = if ($Ctx.PolicySnapshot) {
        foreach ($document in @(Get-IdsExportPolicyDocuments $Ctx 'intent')) {
            $settingsById[$document.policy.id] = $document.settings
            if ($document.policy.templateId) { $templates[$document.policy.templateId] = $document.template }
            $document.policy
        }
    } else { Invoke-IdsGraph -Path '/deviceManagement/intents?$expand=assignments' -All -Tolerant }
    if (-not $items) { return 0 }
    $items = @($items)

    if (-not $Ctx.PolicySnapshot) {
    try {
        foreach ($t in @(Invoke-IdsGraph -Path '/deviceManagement/templates?$select=id,displayName,templateType,platformType' -All -Tolerant)) {
            if ($t -and $t.id) { $templates[$t.id] = $t }
        }
    } catch { }
    }

    foreach ($intent in ($items | Sort-Object displayName)) {
        $settings = @()
        if ($Ctx.PolicySnapshot) { $settings = @($settingsById[$intent.id]) } else {
            try { $settings = @(Invoke-IdsGraph -Path "/deviceManagement/intents/$($intent.id)/settings" -All -Tolerant) } catch { }
        }

        $tpl = $null
        if ($intent.templateId -and $templates.ContainsKey($intent.templateId)) { $tpl = $templates[$intent.templateId] }
        $category = 'general'
        if ($tpl) { $category = New-IdsSlug ([string]$tpl.templateType) }

        $md = New-IdsDocument `
            -Title $intent.displayName -Description $intent.description `
            -FrontMatter ([ordered]@{
                intuneId = $intent.id; objectType = 'deviceManagementIntent'
                template = $(if ($tpl) { $tpl.displayName } else { $intent.templateId })
                lastModified = (Format-IdsDate $intent.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                'Policy type'   = 'Endpoint security'
                'Template'      = $(if ($tpl) { $tpl.displayName } else { $intent.templateId })
                'Template type' = $(if ($tpl) { $tpl.templateType } else { '-' })
                'Platform'      = $(if ($tpl) { $tpl.platformType } else { '-' })
                'Last modified' = (Format-IdsDate $intent.lastModifiedDateTime)
                'Scope tags'    = (Format-IdsScopeTags $intent.roleScopeTagIds)
                'Intune id'     = $intent.id
            }) `
            -Sections ([ordered]@{ 'Settings' = (Format-IdsIntentSettings -Settings $settings) }) `
            -Assignments $intent.assignments -Raw $intent

        Save-IdsDoc -Ctx $Ctx -Section 'Endpoint security' -Folder "endpoint-security/$category" `
            -Title $intent.displayName -Markdown $md -Id $intent.id -RawObject $intent -Assignments $intent.assignments | Out-Null
    }
    return $items.Count
}

function Export-IdsApps {
    param($Ctx)
    $items = Invoke-IdsGraph -Path '/deviceAppManagement/mobileApps?$expand=assignments' -All -Tolerant
    if (-not $items) { return 0 }
    $items = @($items)
    foreach ($a in ($items | Sort-Object displayName)) {
        $type = [string]$a.'@odata.type'
        $platform = Get-IdsAppPlatform $type
        $sections = [ordered]@{ 'Application details' = (Format-IdsAppInstallSettings -App $a) }
        if ($a.PSObject.Properties['detectionRules'] -and $a.detectionRules) {
            $sections['Detection rules'] = (Format-IdsDetectionRules -Rules $a.detectionRules)
        }
        if ($a.PSObject.Properties['requirementRules'] -and $a.requirementRules) {
            $sections['Requirement rules'] = (Format-IdsDetectionRules -Rules $a.requirementRules)
        }
        if ($a.PSObject.Properties['returnCodes'] -and $a.returnCodes) {
            $sections['Return codes'] = New-IdsTable -Headers @('Code', 'Type') -Rows @(
                foreach ($r in @($a.returnCodes)) { , @($r.returnCode, $r.type) })
        }
        $md = New-IdsDocument `
            -Title $a.displayName -Description $a.description `
            -FrontMatter ([ordered]@{
                intuneId = $a.id; objectType = ($type -replace '#microsoft\.graph\.', '')
                platform = $platform; lastModified = (Format-IdsDate $a.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                'App type'      = (Format-IdsAppType $type)
                'Publisher'     = $a.publisher
                'Platform'      = $platform
                'Created'       = (Format-IdsDate $a.createdDateTime)
                'Last modified' = (Format-IdsDate $a.lastModifiedDateTime)
                'Published'     = $a.publishingState
                'Scope tags'    = (Format-IdsScopeTags $a.roleScopeTagIds)
                'Intune id'     = $a.id
            }) `
            -Sections $sections -Assignments $a.assignments -Raw $a

        Save-IdsDoc -Ctx $Ctx -Section 'Applications' -Folder "apps/$platform" `
            -Title $a.displayName -Markdown $md -Id $a.id -RawObject $a -Assignments $a.assignments | Out-Null
    }
    return $items.Count
}

function Export-IdsAppManagementPolicies {
    param($Ctx)
    $total = 0
    $sources = @(
        @{ path = '/deviceAppManagement/iosManagedAppProtections?$expand=assignments'; folder = 'app-management/app-protection/ios'; label = 'App protection policies' }
        @{ path = '/deviceAppManagement/androidManagedAppProtections?$expand=assignments'; folder = 'app-management/app-protection/android'; label = 'App protection policies' }
        @{ path = '/deviceAppManagement/windowsManagedAppProtections?$expand=assignments'; folder = 'app-management/app-protection/windows'; label = 'App protection policies' }
        @{ path = '/deviceAppManagement/targetedManagedAppConfigurations?$expand=assignments'; folder = 'app-management/app-configuration/managed-apps'; label = 'App configuration policies' }
        @{ path = '/deviceAppManagement/mobileAppConfigurations?$expand=assignments'; folder = 'app-management/app-configuration/managed-devices'; label = 'App configuration policies' }
    )
    foreach ($src in $sources) {
        $items = Invoke-IdsGraph -Path $src.path -All -Tolerant
        if (-not $items) { continue }
        foreach ($p in (@($items) | Sort-Object displayName)) {
            $md = New-IdsDocument `
                -Title $p.displayName -Description $p.description `
                -FrontMatter ([ordered]@{
                    intuneId = $p.id; objectType = ([string]$p.'@odata.type' -replace '#microsoft\.graph\.', '')
                    lastModified = (Format-IdsDate $p.lastModifiedDateTime)
                }) `
                -Overview ([ordered]@{
                    'Policy type'   = (Format-IdsOdataType $p.'@odata.type')
                    'Created'       = (Format-IdsDate $p.createdDateTime)
                    'Last modified' = (Format-IdsDate $p.lastModifiedDateTime)
                    'Intune id'     = $p.id
                }) `
                -Sections ([ordered]@{ 'Settings' = (Format-IdsTemplateSettings -Config $p) }) `
                -Assignments $p.assignments -Raw $p
            Save-IdsDoc -Ctx $Ctx -Section $src.label -Folder $src.folder -Title $p.displayName `
                -Markdown $md -Id $p.id -RawObject $p -Assignments $p.assignments | Out-Null
            $total++
        }
    }
    return $total
}

function Export-IdsScripts {
    param($Ctx)
    $total = 0
    $sources = @(
        @{ path = '/deviceManagement/deviceManagementScripts'; folder = 'scripts/windows'; label = 'Scripts'; content = 'scriptContent'; lang = 'powershell' }
        @{ path = '/deviceManagement/deviceShellScripts'; folder = 'scripts/macos'; label = 'Scripts'; content = 'scriptContent'; lang = 'bash' }
        @{ path = '/deviceManagement/deviceCustomAttributeShellScripts'; folder = 'scripts/macos-custom-attributes'; label = 'Scripts'; content = 'scriptContent'; lang = 'bash' }
    )
    foreach ($src in $sources) {
        $list = Invoke-IdsGraph -Path ($src.path + '?$expand=assignments') -All -Tolerant
        if (-not $list) { continue }
        $list = @($list)
        # Script bodies are only returned on a single-item GET.
        $reqs = @()
        foreach ($s in $list) { $reqs += @{ id = $s.id; url = "$($src.path)/$($s.id)" } }
        $details = Invoke-IdsGraphBatch -Requests $reqs

        foreach ($s in ($list | Sort-Object displayName)) {
            $full = $s
            $entry = $details[$s.id]
            if ($entry -and $entry.status -eq 200 -and $entry.body) { $full = $entry.body }

            $sections = [ordered]@{}
            $body = ''
            if ($full.PSObject.Properties[$src.content]) { $body = ConvertFrom-IdsBase64 ([string]$full.$($src.content)) }
            if ($body) {
                if ($Ctx.Options.IncludeScriptContent) {
                    $sections['Script'] = "``````$($src.lang)`n$body`n``````"
                } else {
                    $sections['Script'] = '_Script body omitted (script content disabled for this export)._'
                }
            }
            $md = New-IdsDocument `
                -Title $full.displayName -Description $full.description `
                -FrontMatter ([ordered]@{
                    intuneId = $full.id; objectType = 'deviceManagementScript'
                    lastModified = (Format-IdsDate $full.lastModifiedDateTime)
                }) `
                -Overview ([ordered]@{
                    'File name'         = $full.fileName
                    'Run as account'    = $full.runAsAccount
                    'Run as 32-bit'     = $full.runAs32Bit
                    'Signature check'   = $full.enforceSignatureCheck
                    'Block execution notifications' = $full.blockExecutionNotifications
                    'Created'           = (Format-IdsDate $full.createdDateTime)
                    'Last modified'     = (Format-IdsDate $full.lastModifiedDateTime)
                    'Scope tags'        = (Format-IdsScopeTags $full.roleScopeTagIds)
                    'Intune id'         = $full.id
                }) `
                -Sections $sections -Assignments $s.assignments -Raw $full
            Save-IdsDoc -Ctx $Ctx -Section $src.label -Folder $src.folder -Title $full.displayName `
                -Markdown $md -Id $full.id -RawObject $full -Assignments $s.assignments | Out-Null
            $total++
        }
    }
    return $total
}

function Export-IdsRemediations {
    param($Ctx)
    $list = Invoke-IdsGraph -Path '/deviceManagement/deviceHealthScripts?$expand=assignments' -All -Tolerant
    if (-not $list) { return 0 }
    $list = @($list)
    $reqs = @()
    foreach ($s in $list) { $reqs += @{ id = $s.id; url = "/deviceManagement/deviceHealthScripts/$($s.id)" } }
    $details = Invoke-IdsGraphBatch -Requests $reqs

    foreach ($s in ($list | Sort-Object displayName)) {
        $full = $s
        $entry = $details[$s.id]
        if ($entry -and $entry.status -eq 200 -and $entry.body) { $full = $entry.body }

        $sections = [ordered]@{}
        if ($Ctx.Options.IncludeScriptContent) {
            $det = ConvertFrom-IdsBase64 ([string]$full.detectionScriptContent)
            $rem = ConvertFrom-IdsBase64 ([string]$full.remediationScriptContent)
            if ($det) { $sections['Detection script'] = "``````powershell`n$det`n``````" }
            if ($rem) { $sections['Remediation script'] = "``````powershell`n$rem`n``````" }
        } else {
            $sections['Scripts'] = '_Script bodies omitted (script content disabled for this export)._'
        }
        $md = New-IdsDocument `
            -Title $full.displayName -Description $full.description `
            -FrontMatter ([ordered]@{
                intuneId = $full.id; objectType = 'deviceHealthScript'
                lastModified = (Format-IdsDate $full.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                'Publisher'      = $full.publisher
                'Version'        = $full.version
                'Run as account' = $full.runAsAccount
                'Run as 32-bit'  = $full.runAs32Bit
                'Signature check' = $full.enforceSignatureCheck
                'Created'        = (Format-IdsDate $full.createdDateTime)
                'Last modified'  = (Format-IdsDate $full.lastModifiedDateTime)
                'Scope tags'     = (Format-IdsScopeTags $full.roleScopeTagIds)
                'Intune id'      = $full.id
            }) `
            -Sections $sections -Assignments $s.assignments -Raw $full
        Save-IdsDoc -Ctx $Ctx -Section 'Remediations' -Folder 'scripts/remediations' `
            -Title $full.displayName -Markdown $md -Id $full.id -RawObject $full -Assignments $s.assignments | Out-Null
    }
    return $list.Count
}

function Export-IdsEnrollment {
    param($Ctx)
    $total = 0
    $configs = Invoke-IdsGraph -Path '/deviceManagement/deviceEnrollmentConfigurations?$expand=assignments' -All -Tolerant
    foreach ($c in (@($configs) | Sort-Object priority, displayName)) {
        if (-not $c) { continue }
        $t = [string]$c.'@odata.type'
        $folder = 'enrollment/restrictions'
        if ($t -match 'Windows10EnrollmentCompletionPageConfiguration') { $folder = 'enrollment/enrollment-status-page' }
        elseif ($t -match 'DeviceEnrollmentLimitConfiguration') { $folder = 'enrollment/device-limit' }
        elseif ($t -match 'DeviceEnrollmentWindowsHelloForBusinessConfiguration') { $folder = 'enrollment/windows-hello' }

        $md = New-IdsDocument `
            -Title $c.displayName -Description $c.description `
            -FrontMatter ([ordered]@{
                intuneId = $c.id; objectType = ($t -replace '#microsoft\.graph\.', '')
                lastModified = (Format-IdsDate $c.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                'Configuration type' = (Format-IdsOdataType $t)
                'Priority'           = $c.priority
                'Created'            = (Format-IdsDate $c.createdDateTime)
                'Last modified'      = (Format-IdsDate $c.lastModifiedDateTime)
                'Version'            = $c.version
                'Intune id'          = $c.id
            }) `
            -Sections ([ordered]@{ 'Settings' = (Format-IdsTemplateSettings -Config $c) }) `
            -Assignments $c.assignments -Raw $c
        Save-IdsDoc -Ctx $Ctx -Section 'Enrollment' -Folder $folder -Title $c.displayName `
            -Markdown $md -Id $c.id -RawObject $c -Assignments $c.assignments | Out-Null
        $total++
    }

    $ap = Invoke-IdsGraph -Path '/deviceManagement/windowsAutopilotDeploymentProfiles?$expand=assignments' -All -Tolerant
    foreach ($p in (@($ap) | Sort-Object displayName)) {
        if (-not $p) { continue }
        $md = New-IdsDocument `
            -Title $p.displayName -Description $p.description `
            -FrontMatter ([ordered]@{
                intuneId = $p.id; objectType = 'windowsAutopilotDeploymentProfile'
                lastModified = (Format-IdsDate $p.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                'Profile type'      = (Format-IdsOdataType $p.'@odata.type')
                'Device name template' = $p.deviceNameTemplate
                'Join type'         = $p.deviceType
                'Hybrid join skip connectivity check' = $p.hybridAzureADJoinSkipConnectivityCheck
                'Created'           = (Format-IdsDate $p.createdDateTime)
                'Last modified'     = (Format-IdsDate $p.lastModifiedDateTime)
                'Intune id'         = $p.id
            }) `
            -Sections ([ordered]@{ 'Out-of-box experience' = (Format-IdsTemplateSettings -Config $p) }) `
            -Assignments $p.assignments -Raw $p
        Save-IdsDoc -Ctx $Ctx -Section 'Autopilot' -Folder 'enrollment/autopilot' -Title $p.displayName `
            -Markdown $md -Id $p.id -RawObject $p -Assignments $p.assignments | Out-Null
        $total++
    }
    return $total
}

function Export-IdsReference {
    param($Ctx)
    $total = 0

    $filters = Invoke-IdsGraph -Path '/deviceManagement/assignmentFilters' -All -Tolerant
    foreach ($f in (@($filters) | Sort-Object displayName)) {
        if (-not $f) { continue }
        $sections = [ordered]@{
            'Rule' = ('```' + "`n" + (Format-IdsFilterRule -Rule ([string]$f.rule)) + "`n" + '```')
        }
        # Every assignment that references this filter, so the page answers "where is this used?"
        $usedBy = @($Ctx.Assign | Where-Object { $_.FilterId -eq $f.id } | Sort-Object Section, Object)
        $sections['Used by'] = New-IdsTable -Headers @('Area', 'Object', 'Group', 'Mode') -Rows @(
            foreach ($u in $usedBy) { , @($u.Section, "[$($u.Object)](../../$($u.Path))", $u.Group, $u.FilterMode) }
        ) -EmptyText '_Not used by any assignment._'

        $md = New-IdsDocument `
            -Title $f.displayName -Description $f.description `
            -FrontMatter ([ordered]@{ intuneId = $f.id; objectType = 'assignmentFilter' }) `
            -Overview ([ordered]@{
                'Platform'      = $f.platform
                'Filter type'   = $f.assignmentFilterManagementType
                'Created'       = (Format-IdsDate $f.createdDateTime)
                'Last modified' = (Format-IdsDate $f.lastModifiedDateTime)
                'Used by'       = $usedBy.Count
                'Intune id'     = $f.id
            }) `
            -Sections $sections `
            -Assignments $null -Raw $f
        Save-IdsDoc -Ctx $Ctx -Section 'Assignment filters' -Folder 'reference/filters' -Title $f.displayName `
            -Markdown $md -Id $f.id -RawObject $f -Assignments $null | Out-Null
        $total++
    }

    $roles = Invoke-IdsGraph -Path '/deviceManagement/roleDefinitions' -All -Tolerant
    $customRoles = @($roles | Where-Object { $_ -and -not $_.isBuiltIn })
    foreach ($r in ($customRoles | Sort-Object displayName)) {
        $perms = @()
        foreach ($p in @($r.rolePermissions)) {
            foreach ($ra in @($p.resourceActions)) {
                foreach ($allowed in @($ra.allowedResourceActions)) { $perms += $allowed }
            }
        }
        $md = New-IdsDocument `
            -Title $r.displayName -Description $r.description `
            -FrontMatter ([ordered]@{ intuneId = $r.id; objectType = 'roleDefinition' }) `
            -Overview ([ordered]@{ 'Built in' = $r.isBuiltIn; 'Intune id' = $r.id }) `
            -Sections ([ordered]@{ 'Allowed actions' = (New-IdsTable -Headers @('Action') -Rows @(foreach ($p in ($perms | Sort-Object -Unique)) { , @($p) })) }) `
            -Assignments $null -Raw $r
        Save-IdsDoc -Ctx $Ctx -Section 'Custom roles' -Folder 'reference/roles' -Title $r.displayName `
            -Markdown $md -Id $r.id -RawObject $r -Assignments $null | Out-Null
        $total++
    }
    return $total
}

function Export-IdsGroups {
    param($Ctx)
    $groupObjects = $Ctx.GroupObjects
    if (-not $groupObjects -or $groupObjects.Count -eq 0) { return 0 }
    $count = 0
    foreach ($g in ($groupObjects.Values | Sort-Object displayName)) {
        if (-not $g) { continue }
        $type = 'Assigned security group'
        if ($g.PSObject.Properties['membershipRule'] -and $g.membershipRule) { $type = 'Dynamic group' }
        $sections = [ordered]@{}
        if ($g.PSObject.Properties['membershipRule'] -and $g.membershipRule) {
            $sections['Membership rule'] = ("```````n" + [string]$g.membershipRule + "`n``````")
        }
        $used = @($Ctx.Assign | Where-Object { $_.Group -eq $g.displayName } | Sort-Object Section, Object)
        $sections['Used by'] = New-IdsTable -Headers @('Area', 'Object', 'Mode') -Rows @(
            foreach ($u in $used) { , @($u.Section, "[$($u.Object)](../../$($u.Path))", $u.Mode) })

        $md = New-IdsDocument `
            -Title $g.displayName -Description $g.description `
            -FrontMatter ([ordered]@{ entraGroupId = $g.id; objectType = 'group' }) `
            -Overview ([ordered]@{
                'Group type'       = $type
                'Security enabled' = $g.securityEnabled
                'Mail enabled'     = $g.mailEnabled
                'Entra group id'   = $g.id
            }) `
            -Sections $sections -Assignments $null -Raw $g
        Save-IdsDoc -Ctx $Ctx -Section 'Groups' -Folder 'reference/groups' -Title $g.displayName `
            -Markdown $md -Id $g.id -RawObject $g -Assignments $null | Out-Null
        $count++
    }
    return $count
}

# --- Cross-cutting reports --------------------------------------------------------------

function Write-IdsAssignmentReports {
    param($Ctx)
    $all = @($Ctx.Assign)

    $byGroup = @()
    foreach ($grp in ($all | Where-Object { $_.Mode -ne 'Unassigned' } | Group-Object Group | Sort-Object Name)) {
        $byGroup += "## $($grp.Name)"
        $byGroup += ''
        $byGroup += New-IdsTable -Headers @('Area', 'Object', 'Mode', 'Intent', 'Filter') -Rows @(
            foreach ($r in ($grp.Group | Sort-Object Section, Object)) {
                , @($r.Section, "[$($r.Object)](../$($r.Path))", $r.Mode, $r.Intent, $r.Filter)
            })
        $byGroup += ''
    }
    $doc = @('# Assignments by group', '', 'Every Intune object targeted at each Entra ID group.', '') + $byGroup
    $rel = 'assignments/by-group.md'
    $Ctx.Stats[(Write-IdsFile -Path (Join-Path $Ctx.Root 'assignments\by-group.md') -Content (($doc -join "`n").TrimEnd() + "`n"))]++
    [void]$Ctx.Written.Add($rel)

    $byObject = @('# Assignments by object', '')
    foreach ($sec in ($all | Group-Object Section | Sort-Object Name)) {
        $byObject += "## $($sec.Name)"
        $byObject += ''
        $byObject += New-IdsTable -Headers @('Object', 'Included', 'Excluded') -Rows @(
            foreach ($obj in ($sec.Group | Group-Object Object | Sort-Object Name)) {
                $inc = @($obj.Group | Where-Object { $_.Mode -eq 'Included' } | ForEach-Object { $_.Group })
                $exc = @($obj.Group | Where-Object { $_.Mode -eq 'Excluded' } | ForEach-Object { $_.Group })
                $path = @($obj.Group)[0].Path
                , @("[$($obj.Name)](../$path)", ($inc -join ', '), ($exc -join ', '))
            })
        $byObject += ''
    }
    $rel2 = 'assignments/by-object.md'
    $Ctx.Stats[(Write-IdsFile -Path (Join-Path $Ctx.Root 'assignments\by-object.md') -Content (($byObject -join "`n").TrimEnd() + "`n"))]++
    [void]$Ctx.Written.Add($rel2)

    $unassigned = @($all | Where-Object { $_.Mode -eq 'Unassigned' } | Sort-Object Section, Object)
    $un = @('# Unassigned objects', '',
        'These objects exist in the tenant but target no group. They are candidates for clean-up.', '')
    $un += New-IdsTable -Headers @('Area', 'Object') -Rows @(
        foreach ($r in $unassigned) { , @($r.Section, "[$($r.Object)](../$($r.Path))") }) -EmptyText '_Every object is assigned._'
    $rel3 = 'assignments/unassigned.md'
    $Ctx.Stats[(Write-IdsFile -Path (Join-Path $Ctx.Root 'assignments\unassigned.md') -Content (($un -join "`n").TrimEnd() + "`n"))]++
    [void]$Ctx.Written.Add($rel3)
}

function Write-IdsIndex {
    param($Ctx, [hashtable]$Meta)
    $lines = @('# Intune configuration documentation', '')
    $lines += "Tenant: **$($Meta.organization)**"
    $lines += ''
    $lines += '| Area | Objects |'
    $lines += '|---|---|'
    foreach ($k in $Ctx.Index.Keys) { $lines += "| $k | $(@($Ctx.Index[$k]).Count) |" }
    $lines += ''
    $lines += '## Reports'
    $lines += ''
    $lines += '- [Assignments by group](assignments/by-group.md)'
    $lines += '- [Assignments by object](assignments/by-object.md)'
    $lines += '- [Unassigned objects](assignments/unassigned.md)'
    $lines += ''
    foreach ($k in $Ctx.Index.Keys) {
        $lines += "## $k"
        $lines += ''
        foreach ($e in (@($Ctx.Index[$k]) | Sort-Object { $_.title })) {
            $lines += '- [' + $e.title + '](' + $e.path + ')'
        }
        $lines += ''
    }
    $content = ($lines -join "`n").TrimEnd() + "`n"
    $Ctx.Stats[(Write-IdsFile -Path (Join-Path $Ctx.Root 'index.md') -Content $content)]++
    [void]$Ctx.Written.Add('index.md')
}

function Write-IdsReadme {
    param($Ctx, [hashtable]$Meta, [bool]$ContentChanged = $true)
    $readmePath = Join-Path $Ctx.Root 'README.md'

    # When nothing in the tenant changed, keep the previous "Generated" value. Otherwise the
    # timestamp alone would produce a commit on every run and bury real drift in noise.
    $generated = $Meta.generated
    if (-not $ContentChanged -and (Test-Path -LiteralPath $readmePath)) {
        try {
            $prev = Select-String -LiteralPath $readmePath -Pattern '^\| Generated \| (.+) \|$' | Select-Object -First 1
            if ($prev) { $generated = $prev.Matches[0].Groups[1].Value }
        } catch { }
    }

    $lines = @()
    $lines += '# Intune configuration documentation'
    $lines += ''
    $lines += "Generated by **Intune Docs Studio** — no Entra ID app registration required."
    $lines += ''
    $lines += '| | |'
    $lines += '|---|---|'
    $lines += "| Tenant | $($Meta.organization) |"
    $lines += "| Tenant id | $($Meta.tenantId) |"
    $lines += "| Exported by | $($Meta.account) |"
    $lines += "| Sign-in method | $($Meta.method) |"
    $lines += "| Generated | $generated |"
    if ($Meta.policiesCapturedAt) { $lines += "| Policies loaded | $($Meta.policiesCapturedAt) |" }
    $lines += "| Objects documented | $($Meta.totalObjects) |"
    $lines += ''
    $lines += '## Contents'
    $lines += ''
    $lines += '| Area | Objects |'
    $lines += '|---|---|'
    foreach ($k in $Ctx.Counts.Keys) { $lines += "| $k | $($Ctx.Counts[$k]) |" }
    $lines += ''
    $lines += '- Full table of contents: [index.md](index.md)'
    $lines += '- Assignment reports: [by group](assignments/by-group.md) · [by object](assignments/by-object.md) · [unassigned](assignments/unassigned.md)'
    $lines += ''
    if (@($Ctx.Warnings).Count -gt 0) {
        $lines += '## Warnings'
        $lines += ''
        foreach ($w in $Ctx.Warnings) { $lines += "- $w" }
        $lines += ''
    }
    $lines += '## How this is produced'
    $lines += ''
    $lines += 'The exporter signs in interactively as an administrator using a Microsoft first-party'
    $lines += 'public client and requests read-only delegated Graph permissions. No application'
    $lines += 'registration is created, no client secret exists, and the export is limited to whatever'
    $lines += 'the signing-in administrator is permitted to read.'
    $lines += ''
    $lines += 'Re-running the export overwrites only what changed, so the commit history of this'
    $lines += 'repository is an audit trail of Intune configuration drift.'
    $lines += ''
    if ($Ctx.Options.IncludeScriptContent) {
        $lines += '> **Note** — script bodies and custom payloads are included in this export.'
        $lines += '> Review repository access accordingly.'
        $lines += ''
    }
    $content = ($lines -join "`n").TrimEnd() + "`n"
    $Ctx.Stats[(Write-IdsFile -Path (Join-Path $Ctx.Root 'README.md') -Content $content)]++
    [void]$Ctx.Written.Add('README.md')
}

function Write-IdsNavigation {
    <#  Generates folder landing pages and .order files.

        Azure DevOps 'publish code as wiki' pairs a folder with a same-named sibling .md to
        form a parent page, and uses .order to sequence children. Producing both makes the
        export browse cleanly in Azure DevOps, GitHub and a plain editor alike. #>
    param($Ctx)

    # Collect every markdown page and synthesise the full ancestor chain of directories.
    $dirFiles = @{}
    $dirSubs = @{}
    $allDirs = New-Object System.Collections.Generic.HashSet[string]
    [void]$allDirs.Add('')

    foreach ($rel in @($Ctx.Written)) {
        if ($rel -notlike '*.md') { continue }
        if ($rel -like '_raw/*') { continue }
        $dir = ''
        $name = $rel
        if ($rel.Contains('/')) {
            $dir = $rel.Substring(0, $rel.LastIndexOf('/'))
            $name = $rel.Substring($rel.LastIndexOf('/') + 1)
        }
        if (-not $dirFiles.ContainsKey($dir)) { $dirFiles[$dir] = New-Object System.Collections.ArrayList }
        [void]$dirFiles[$dir].Add([IO.Path]::GetFileNameWithoutExtension($name))

        $parts = @()
        if ($dir) { $parts = $dir.Split('/') }
        $acc = ''
        foreach ($p in $parts) {
            $parent = $acc
            if ($acc) { $acc = "$acc/$p" } else { $acc = $p }
            [void]$allDirs.Add($acc)
            if (-not $dirSubs.ContainsKey($parent)) { $dirSubs[$parent] = New-Object System.Collections.Generic.HashSet[string] }
            [void]$dirSubs[$parent].Add($p)
        }
    }

    # Landing page for each folder, written as a sibling of that folder.
    foreach ($dir in @($allDirs)) {
        if (-not $dir) { continue }
        $leaf = $dir.Split('/')[-1]
        $title = ($leaf -replace '-', ' ')
        $title = $title.Substring(0, 1).ToUpperInvariant() + $title.Substring(1)

        $lines = @("# $title", '')
        $subs = @()
        if ($dirSubs.ContainsKey($dir)) { $subs = @($dirSubs[$dir] | Sort-Object) }
        if ($subs.Count -gt 0) {
            $lines += '## Sections'
            $lines += ''
            foreach ($s in $subs) { $lines += '- [' + ($s -replace '-', ' ') + '](' + $leaf + '/' + $s + '.md)' }
            $lines += ''
        }
        $files = @()
        if ($dirFiles.ContainsKey($dir)) { $files = @($dirFiles[$dir] | Sort-Object) }
        if ($files.Count -gt 0) {
            $lines += '## Pages'
            $lines += ''
            foreach ($f in $files) { $lines += '- [' + $f + '](' + $leaf + '/' + $f + '.md)' }
            $lines += ''
        }
        if ($subs.Count -eq 0 -and $files.Count -eq 0) { $lines += '_No items._' }

        $rel = "$dir.md"
        $full = Join-Path $Ctx.Root ($rel -replace '/', '\')
        $Ctx.Stats[(Write-IdsFile -Path $full -Content (($lines -join "`n").TrimEnd() + "`n"))]++
        [void]$Ctx.Written.Add($rel)

        # The landing page itself is a page of its parent folder.
        $parent = ''
        if ($dir.Contains('/')) { $parent = $dir.Substring(0, $dir.LastIndexOf('/')) }
        if (-not $dirFiles.ContainsKey($parent)) { $dirFiles[$parent] = New-Object System.Collections.ArrayList }
        if (-not $dirFiles[$parent].Contains($leaf)) { [void]$dirFiles[$parent].Add($leaf) }
    }

    if (-not $Ctx.Options.AdoWikiOrder) { return }

    foreach ($dir in @($allDirs)) {
        $entries = @()
        if ($dirFiles.ContainsKey($dir)) { $entries += @($dirFiles[$dir]) }
        $entries = @($entries | Sort-Object -Unique)
        if ($entries.Count -eq 0) { continue }

        # README and index lead the root page order; everything else is alphabetical.
        if (-not $dir) {
            $lead = @()
            foreach ($n in @('README', 'index')) { if ($entries -contains $n) { $lead += $n } }
            $rest = @($entries | Where-Object { $_ -ne 'README' -and $_ -ne 'index' })
            $entries = $lead + $rest
        }

        $rel = '.order'
        $path = Join-Path $Ctx.Root '.order'
        if ($dir) {
            $rel = "$dir/.order"
            $path = Join-Path $Ctx.Root (($dir -replace '/', '\') + '\.order')
        }
        $Ctx.Stats[(Write-IdsFile -Path $path -Content (($entries -join "`n") + "`n"))]++
        [void]$Ctx.Written.Add($rel)
    }
}

function Write-IdsRepoFiles {
    param($Ctx)
    $gitattributes = @('* text=auto eol=lf', '*.md text eol=lf', '*.json text eol=lf') -join "`n"
    $Ctx.Stats[(Write-IdsFile -Path (Join-Path $Ctx.Root '.gitattributes') -Content ($gitattributes + "`n"))]++
    [void]$Ctx.Written.Add('.gitattributes')
}

function Remove-IdsStaleFiles {
    <#  Deletes files this run did not write but a previous run did. Anything the customer
        added by hand is untouched because it never appears in the manifest.

        SAFETY: if any section failed to collect, pruning is skipped entirely. Deleting pages
        because a Graph call happened to fail would fabricate "this policy was removed" drift
        in the commit history — far worse than leaving a stale page for one run. #>
    param($Ctx, [bool]$Complete = $true)
    $manifestPath = Join-Path $Ctx.Root '.intune-docs-manifest.json'
    $previous = @()
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($m.files) { $previous = @($m.files) }
        } catch { }
    }

    if (-not $Complete) {
        Write-IdsLog -State $Ctx.State -Message 'Skipping clean-up of removed objects: this run was incomplete.' -Level 'warn'
        # Preserve the previous manifest entries so nothing is orphaned or lost.
        foreach ($rel in $previous) { [void]$Ctx.Written.Add($rel) }
    } else {
        foreach ($rel in $previous) {
            if ($Ctx.Written.Contains($rel)) { continue }
            $full = Join-Path $Ctx.Root ($rel -replace '/', '\')
            if (Test-Path -LiteralPath $full) {
                Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
                $Ctx.Stats.deleted++
                Write-IdsLog -State $Ctx.State -Message "Removed $rel (no longer present in Intune)"
            }
        }
        # Clear out directories left empty by the prune.
        for ($pass = 0; $pass -lt 4; $pass++) {
            Get-ChildItem -LiteralPath $Ctx.Root -Directory -Recurse -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    if ($_.Name -eq '.git') { return }
                    if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
        }
    }

    # The manifest deliberately carries no timestamp: it is a file list, and a timestamp
    # would make it change on every run even when the tenant did not. The tenant id IS
    # recorded, so a later run can refuse to overwrite another tenant's documentation.
    $manifest = [ordered]@{
        tenantId = [string]$Ctx.TenantId
        tenant   = [string]$Ctx.TenantName
        files    = @($Ctx.Written | Sort-Object)
    }
    [void](Write-IdsFile -Path $manifestPath -Content (ConvertTo-Json $manifest -Depth 5))
}

function Test-IdsOutputFolderTenant {
    <#  Guards against pointing a second tenant at the first tenant's folder. Because the
        manifest drives pruning, that would delete every page of tenant A and replace it with
        tenant B — destroying the documentation and producing a meaningless commit.

        Returns $null when the folder is safe to use, or a description of the conflict. #>
    param([string]$Root, [string]$TenantId, [string]$TenantName)
    $manifestPath = Join-Path $Root '.intune-docs-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }
    try {
        $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch { return $null }

    $existing = ''
    if ($m.PSObject.Properties['tenantId']) { $existing = [string]$m.tenantId }
    # Manifests written before this guard existed carry no tenant: adopt them silently.
    if (-not $existing) { return $null }
    if (-not $TenantId -or $existing -eq $TenantId) { return $null }

    $existingName = ''
    if ($m.PSObject.Properties['tenant']) { $existingName = [string]$m.tenant }
    $whoFrom = $existing
    if ($existingName) { $whoFrom = "$existingName ($existing)" }
    $whoTo = $TenantId
    if ($TenantName) { $whoTo = "$TenantName ($TenantId)" }
    return "This folder already contains documentation for $whoFrom, but you are signed in to $whoTo. Exporting here would delete the existing tenant's documentation. Choose a different output folder."
}

# --- Git --------------------------------------------------------------------------------

function Invoke-IdsGitCommand {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Windows PowerShell wraps native stderr in ErrorRecords, even for successful Git commands.
        $output = & git @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($output | Out-String).Trim()
    } finally { $ErrorActionPreference = $previous }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments[0]) failed (exit $exitCode): $text"
    }
    return @{ Output = $text; ExitCode = $exitCode }
}

function ConvertTo-IdsGitRemoteUrl {
    param([string]$Url)
    $url = $Url.Trim().TrimEnd('/')
    $uri = $null
    if ([uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and $uri.UserInfo) {
        $organization = ''
        if ($uri.Host -eq 'dev.azure.com') { $organization = ($uri.AbsolutePath -split '/')[1] }
        elseif ($uri.Host -match '^([a-zA-Z0-9-]+)\.visualstudio\.com$') { $organization = $Matches[1] }
        # Azure DevOps includes a non-secret organization username in copied HTTPS clone links.
        if ($organization -and $uri.UserInfo -eq $organization) {
            $builder = New-Object UriBuilder($uri)
            $builder.UserName = ''
            $builder.Password = ''
            return $builder.Uri.AbsoluteUri.TrimEnd('/')
        }
    }
    return $url
}

function Assert-IdsGitOptions {
    param([hashtable]$Options)
    if ($Options.GitPush) { $Options.GitCommit = $true }
    $Options.GitRemoteUrl = ConvertTo-IdsGitRemoteUrl -Url ([string]$Options.GitRemoteUrl)
    $Options.GitBranch = ([string]$Options.GitBranch).Trim()
    if ($Options.GitRemoteUrl) {
        $url = $Options.GitRemoteUrl
        $valid = $url -cmatch '^git@ssh\.dev\.azure\.com:v3/[^/\s]+/[^/\s]+/[^/\s?#]+$'
        $uri = $null
        if ([uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) {
            $https = $uri.Scheme -eq 'https' -and -not $uri.UserInfo -and
                ($uri.Host -eq 'dev.azure.com' -or $uri.Host -match '^[a-zA-Z0-9-]+\.visualstudio\.com$') -and
                $uri.AbsolutePath -match '^/(?:[^/]+/)+_git/[^/]+/?$'
            $ssh = $uri.Scheme -eq 'ssh' -and $uri.Host -eq 'ssh.dev.azure.com' -and
                $uri.UserInfo -eq 'git' -and $uri.AbsolutePath -match '^/v3/[^/]+/[^/]+/[^/]+$'
            $valid = $valid -or (($https -or $ssh) -and -not $uri.Query -and -not $uri.Fragment)
        }
        if (-not $valid) {
            throw 'Enter an Azure DevOps HTTPS or SSH clone URL without embedded credentials, query strings, or fragments. Use Git Credential Manager for HTTPS sign-in.'
        }
        if (-not $Options.GitCommit) { throw 'Enable Commit to git or Push to remote when specifying a repository URL.' }
    }
    if ($Options.GitCommit -or $Options.GitBranch) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git was not found on PATH. Install Git for Windows to commit or publish documentation.' }
    }
    if ($Options.GitBranch) {
        Invoke-IdsGitCommand -Arguments @('check-ref-format', '--branch', $Options.GitBranch) | Out-Null
    }
}

function Initialize-IdsGitRepository {
    param($Ctx)
    if (-not $Ctx.Options.GitCommit -and -not $Ctx.Options.GitPush) { return }
    $root = $Ctx.Root
    $url = $Ctx.Options.GitRemoteUrl
    $branch = $Ctx.Options.GitBranch
    $hasRepository = Test-Path -LiteralPath (Join-Path $root '.git')
    if (-not $hasRepository) {
        if ($url) {
            if (@(Get-ChildItem -LiteralPath $root -Force).Count -gt 0) {
                throw 'The output folder is not empty and is not a Git checkout. Choose an empty folder to clone the Azure DevOps repository, or use an existing matching checkout.'
            }
            Invoke-IdsGitCommand -Arguments @('clone', '--origin', 'origin', '--', $url, $root) | Out-Null
            Write-IdsLog -State $Ctx.State -Message 'Cloned the documentation repository'
        } elseif ($Ctx.Options.GitPush) {
            throw 'No Git repository configured. Enter an Azure DevOps repository URL or select a checkout with a configured remote.'
        } else {
            Invoke-IdsGitCommand -Arguments @('-C', $root, 'init', '--quiet') | Out-Null
            Write-IdsLog -State $Ctx.State -Message 'Initialised a new git repository'
        }
    }
    if (-not $url -and -not $Ctx.Options.GitPush -and -not $branch) { return }

    $status = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'status', '--porcelain', '--untracked-files=all')).Output
    if ($status) { throw 'The publishing checkout has uncommitted changes. Commit or stash them before exporting so unrelated files are not published.' }
    foreach ($operation in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply', 'sequencer')) {
        $operationPath = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'rev-parse', '--git-path', $operation)).Output
        if (-not [IO.Path]::IsPathRooted($operationPath)) { $operationPath = Join-Path $root $operationPath }
        if (Test-Path -LiteralPath $operationPath) { throw 'A Git merge, rebase, or cherry-pick is in progress. Complete or abort it before exporting.' }
    }
    $remotes = @((Invoke-IdsGitCommand -Arguments @('-C', $root, 'remote')).Output -split '\r?\n')
    if ($url) {
        if ($remotes -contains 'origin') {
            $existing = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'remote', 'get-url', 'origin')).Output
            if ((ConvertTo-IdsGitRemoteUrl -Url $existing) -cne (ConvertTo-IdsGitRemoteUrl -Url $url)) {
                throw 'The output checkout points to a different origin. Choose a matching checkout or an empty output folder; the existing remote has not been replaced.'
            }
            $pushUrls = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'remote', 'get-url', '--push', '--all', 'origin')).Output
            if ((ConvertTo-IdsGitRemoteUrl -Url $pushUrls) -cne (ConvertTo-IdsGitRemoteUrl -Url $url)) { throw 'The origin push URL differs from the selected repository. Correct the Git remote configuration before publishing.' }
        } else {
            Invoke-IdsGitCommand -Arguments @('-C', $root, 'remote', 'add', 'origin', $url) | Out-Null
        }
        Invoke-IdsGitCommand -Arguments @('-C', $root, 'fetch', '--prune', 'origin') | Out-Null
    }

    $head = Invoke-IdsGitCommand -Arguments @('-C', $root, 'rev-parse', '--verify', 'HEAD') -AllowFailure
    if ($head.ExitCode -ne 0) {
        if (-not $branch -and $url) { $branch = 'main' }
        if ($branch) {
            $remoteRef = "refs/remotes/origin/$branch"
            $remoteHead = Invoke-IdsGitCommand -Arguments @('-C', $root, 'show-ref', '--verify', $remoteRef) -AllowFailure
            if ($remoteHead.ExitCode -eq 0) {
                Invoke-IdsGitCommand -Arguments @('-C', $root, 'checkout', '-B', $branch, '--track', "origin/$branch") | Out-Null
            } else {
                $remoteBranches = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'for-each-ref', '--format=%(refname)', 'refs/remotes/origin/')).Output
                if ($remoteBranches) { throw 'The populated remote has no usable default branch. Select an existing target branch or correct the remote default branch before exporting.' }
                Invoke-IdsGitCommand -Arguments @('-C', $root, 'symbolic-ref', 'HEAD', "refs/heads/$branch") | Out-Null
            }
        }
    } elseif ($branch) {
        $current = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'branch', '--show-current')).Output
        if ($current -cne $branch) {
            $localRef = Invoke-IdsGitCommand -Arguments @('-C', $root, 'show-ref', '--verify', "refs/heads/$branch") -AllowFailure
            $remoteRef = Invoke-IdsGitCommand -Arguments @('-C', $root, 'show-ref', '--verify', "refs/remotes/origin/$branch") -AllowFailure
            if ($localRef.ExitCode -eq 0) {
                Invoke-IdsGitCommand -Arguments @('-C', $root, 'checkout', $branch) | Out-Null
            } elseif ($remoteRef.ExitCode -eq 0) {
                Invoke-IdsGitCommand -Arguments @('-C', $root, 'checkout', '-b', $branch, '--track', "origin/$branch") | Out-Null
            } else {
                Invoke-IdsGitCommand -Arguments @('-C', $root, 'checkout', '-b', $branch) | Out-Null
            }
        }
    }
    $current = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'symbolic-ref', '--quiet', '--short', 'HEAD')).Output
    if ($url) {
        $remoteRef = Invoke-IdsGitCommand -Arguments @('-C', $root, 'show-ref', '--verify', "refs/remotes/origin/$current") -AllowFailure
        if ($remoteRef.ExitCode -eq 0) {
            Invoke-IdsGitCommand -Arguments @('-C', $root, 'merge', '--ff-only', "origin/$current") | Out-Null
        }
    }
    if ($Ctx.Options.GitPush -and -not $url -and -not ($remotes | Where-Object { $_ })) {
        throw 'No git remote configured. Enter an Azure DevOps repository URL or configure a remote in the output checkout.'
    }
}

function Invoke-IdsGit {
    param($Ctx, [hashtable]$Meta)
    if (-not $Ctx.Options.GitCommit -and -not $Ctx.Options.GitPush) { return $null }

    Push-Location $Ctx.Root
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $Ctx.Root '.git'))) {
            Invoke-IdsGitCommand -Arguments @('init', '--quiet') | Out-Null
            Write-IdsLog -State $Ctx.State -Message 'Initialised a new git repository'
        }
        Invoke-IdsGitCommand -Arguments @('add', '-A') | Out-Null
        $status = (Invoke-IdsGitCommand -Arguments @('status', '--porcelain')).Output
        $msg = $Ctx.Options.GitMessage
        if (-not $msg) { $msg = "Intune configuration export $($Meta.generated)" }
        $result = @{ committed = $false; message = 'no changes'; pushed = $false }
        if ($status) {
            Invoke-IdsGitCommand -Arguments @('-c', 'user.name=Intune Docs Studio', '-c', 'user.email=intune-docs-studio@localhost',
                'commit', '-m', $msg, '--quiet') | Out-Null
            Write-IdsLog -State $Ctx.State -Message "Committed changes: $msg"
            $result.committed = $true
            $result.message = $msg
        } else {
            Write-IdsLog -State $Ctx.State -Message 'No configuration changes since the last export; nothing to commit.'
        }

        if ($Ctx.Options.GitPush) {
            $branch = (Invoke-IdsGitCommand -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')).Output
            $remotes = @((Invoke-IdsGitCommand -Arguments @('remote')).Output -split '\r?\n')
            $upstream = Invoke-IdsGitCommand -Arguments @('rev-parse', '--abbrev-ref', '@{upstream}') -AllowFailure
            if ($Ctx.Options.GitRemoteUrl) {
                Invoke-IdsGitCommand -Arguments @('push', '--set-upstream', 'origin', "HEAD:refs/heads/$branch") | Out-Null
            } elseif ($upstream.ExitCode -eq 0) {
                Invoke-IdsGitCommand -Arguments @('push') | Out-Null
            } elseif ($remotes -contains 'origin') {
                Invoke-IdsGitCommand -Arguments @('push', '--set-upstream', 'origin', "HEAD:refs/heads/$branch") | Out-Null
            } elseif (@($remotes | Where-Object { $_ }).Count -eq 1) {
                Invoke-IdsGitCommand -Arguments @('push', '--set-upstream', $remotes[0], "HEAD:refs/heads/$branch") | Out-Null
            } else {
                throw 'No unambiguous push destination. Configure an upstream branch or an origin remote.'
            }
            $result.pushed = $true
            Write-IdsLog -State $Ctx.State -Message 'Pushed to remote'
        }
        return $result
    } finally { Pop-Location }
}

# --- Orchestrator -----------------------------------------------------------------------

function Get-IdsSectionCatalog {
    return [ordered]@{
        'settingsCatalog'   = @{ label = 'Settings catalog'; fn = 'Export-IdsSettingsCatalog'; weight = 25 }
        'deviceConfigs'     = @{ label = 'Configuration profiles'; fn = 'Export-IdsDeviceConfigurations'; weight = 10 }
        'admx'              = @{ label = 'Administrative templates'; fn = 'Export-IdsAdministrativeTemplates'; weight = 10 }
        'compliance'        = @{ label = 'Compliance policies'; fn = 'Export-IdsCompliance'; weight = 6 }
        'endpointSecurity'  = @{ label = 'Endpoint security'; fn = 'Export-IdsEndpointSecurity'; weight = 10 }
        'apps'              = @{ label = 'Applications'; fn = 'Export-IdsApps'; weight = 15 }
        'appManagement'     = @{ label = 'App protection & configuration'; fn = 'Export-IdsAppManagementPolicies'; weight = 6 }
        'scripts'           = @{ label = 'Scripts'; fn = 'Export-IdsScripts'; weight = 6 }
        'remediations'      = @{ label = 'Remediations'; fn = 'Export-IdsRemediations'; weight = 5 }
        'enrollment'        = @{ label = 'Enrollment & Autopilot'; fn = 'Export-IdsEnrollment'; weight = 5 }
        'reference'         = @{ label = 'Filters & roles'; fn = 'Export-IdsReference'; weight = 4 }
        'groups'            = @{ label = 'Groups'; fn = 'Export-IdsGroups'; weight = 4 }
    }
}

function Start-IdsExport {
    <#  Entry point used by both the dashboard runspace and the CLI. #>
    param([hashtable]$State, [hashtable]$Options, $PolicySnapshot)

    $State.Export.running = $true
    $State.Export.done = $false
    $State.Export.error = $null
    $State.Export.percent = 0
    $State.Export.summary = $null

    try {
        Assert-IdsGitOptions -Options $Options
        if ($PolicySnapshot.source.kind -eq 'offline' -and @($Options.Sections | Where-Object {
            $_ -notin @('settingsCatalog', 'deviceConfigs', 'admx', 'compliance', 'endpointSecurity')
        }).Count) { throw 'Offline documentation cannot collect apps, scripts or other live sections.' }
        $root = $Options.OutputPath
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
        $root = (Resolve-Path -LiteralPath $root).Path

        Set-IdsRenderOptions -Options @{
            IncludeRaw           = [bool]$Options.IncludeRaw
            IncludeScriptContent = [bool]$Options.IncludeScriptContent
            FrontMatter          = [bool]$Options.FrontMatter
        }

        $ctx = New-IdsContext -Root $root -Options $Options -State $State
        $ctx.PolicySnapshot = $PolicySnapshot
        Write-IdsLog -State $State -Message "Output folder: $root"

        if ($Options.GitCommit) {
            Set-IdsProgress -State $State -Percent 1 -Phase 'Preparing documentation repository'
            Initialize-IdsGitRepository -Ctx $ctx
        }

        $conn = if ($PolicySnapshot) {
            if ($PolicySnapshot.source.kind -ne 'offline' -and
                (-not $State.Auth -or ($State.Auth.tenant_id -and $State.Auth.tenant_id -ne $PolicySnapshot.tenant.id))) {
                throw 'Loaded policies do not belong to the current tenant.'
            }
            Write-IdsLog -State $State -Message "Using $($PolicySnapshot.source.kind) policies collected at $($PolicySnapshot.capturedAt)."
            @{ tenantId = $PolicySnapshot.tenant.id; organization = $PolicySnapshot.tenant.name }
        } else { Test-IdsGraphConnection }
        $ctx.TenantId = $conn.tenantId
        $ctx.TenantName = $conn.organization

        # Refuse to overwrite another tenant's documentation before anything is written.
        $conflict = Test-IdsOutputFolderTenant -Root $root -TenantId $conn.tenantId -TenantName $conn.organization
        if ($conflict -and -not $Options.AllowTenantOverwrite) { throw $conflict }

        Initialize-IdsLookups -Ctx $ctx

        $meta = @{
            organization = $conn.organization
            tenantId     = $conn.tenantId
            account      = $State.Auth.account
            method       = $State.Auth.method
            generated    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
            policiesCapturedAt = $PolicySnapshot.capturedAt
            totalObjects = 0
        }

        $catalog = Get-IdsSectionCatalog
        $selected = @($Options.Sections)
        $active = @($catalog.Keys | Where-Object { $selected -contains $_ })
        $totalWeight = 0
        foreach ($k in $active) { $totalWeight += $catalog[$k].weight }
        if ($totalWeight -eq 0) { $totalWeight = 1 }
        $done = 0
        $failedSections = @()

        foreach ($key in $active) {
            $sec = $catalog[$key]
            Set-IdsProgress -State $State -Percent ([int](5 + 85 * $done / $totalWeight)) -Phase $sec.label
            Write-IdsLog -State $State -Message "Collecting $($sec.label)…"
            try {
                $count = & $sec.fn -Ctx $ctx
                if ($null -eq $count) { $count = 0 }
                $ctx.Counts[$sec.label] = $count
                $meta.totalObjects += [int]$count
                Write-IdsLog -State $State -Message "$($sec.label): $count object(s)"
            } catch {
                $where = ''
                try {
                    $inv = $_.InvocationInfo
                    if ($inv) { $where = " [$($inv.ScriptName | Split-Path -Leaf):$($inv.ScriptLineNumber)]" }
                } catch { }
                Add-IdsWarning $ctx "$($sec.label) failed: $($_.Exception.Message)$where"
                $ctx.Counts[$sec.label] = 0
                $failedSections += $sec.label
            }
            $done += $sec.weight
        }

        Set-IdsProgress -State $State -Percent 92 -Phase 'Building reports'

        # Snapshot before the summary files are written, so "did anything change?" reflects
        # the tenant's objects rather than the report pages describing them.
        $contentChanged = ($ctx.Stats.created + $ctx.Stats.updated + $ctx.Stats.deleted) -gt 0

        # Surface systematic group-resolution problems: they change how the assignment
        # reports should be read, and usually point at a missing Group.Read.All grant.
        if ($ctx.GroupErrors -and $ctx.GroupErrors.Count -gt 0) {
            $forbidden = @($ctx.GroupErrors.Values | Where-Object { $_ -eq 403 }).Count
            $missing = @($ctx.GroupErrors.Values | Where-Object { $_ -eq 404 }).Count
            if ($forbidden -gt 0) {
                Add-IdsWarning $ctx "$forbidden assignment group(s) could not be read (HTTP 403). The sign-in lacks Group.Read.All, so those assignments show a group id instead of a name."
            }
            if ($missing -gt 0) {
                Add-IdsWarning $ctx "$missing assignment group(s) no longer exist in Entra ID (HTTP 404). Those assignments target deleted groups and are candidates for clean-up."
            }
        }

        Write-IdsAssignmentReports -Ctx $ctx
        Write-IdsIndex -Ctx $ctx -Meta $meta
        Write-IdsReadme -Ctx $ctx -Meta $meta -ContentChanged $contentChanged
        Write-IdsRepoFiles -Ctx $ctx
        Write-IdsNavigation -Ctx $ctx

        Set-IdsProgress -State $State -Percent 96 -Phase 'Pruning removed objects'
        Remove-IdsStaleFiles -Ctx $ctx -Complete ($failedSections.Count -eq 0 -and -not $ctx.OfflineIncomplete)

        $git = $null
        if ($Options.GitCommit) {
            Set-IdsProgress -State $State -Percent 98 -Phase 'Committing to git'
            $git = Invoke-IdsGit -Ctx $ctx -Meta $meta
        }

        $State.Export.summary = @{
            root      = $root
            meta      = $meta
            counts    = $ctx.Counts
            stats     = $ctx.Stats
            warnings  = @($ctx.Warnings)
            failed    = @($failedSections)
            complete  = ($failedSections.Count -eq 0 -and -not $ctx.OfflineIncomplete)
            git       = $git
            graph     = $(if ($PolicySnapshot.source.kind -eq 'offline') { @{ requests = 0 } } else { Get-IdsGraphStats })
            files     = @($ctx.Written).Count
        }
        Set-IdsProgress -State $State -Percent 100 -Phase 'Complete'
        Write-IdsLog -State $State -Message "Done. $($ctx.Stats.created) created, $($ctx.Stats.updated) updated, $($ctx.Stats.unchanged) unchanged, $($ctx.Stats.deleted) removed."
    } catch {
        $State.Export.error = $_.Exception.Message
        Write-IdsLog -State $State -Message "Export failed: $($_.Exception.Message)" -Level 'error'
    } finally {
        $State.Export.running = $false
        $State.Export.done = $true
    }
}
