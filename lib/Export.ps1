. (Join-Path $PSScriptRoot 'Localization.ps1')

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
            $Markdown = (Get-IdsText 'doc.offline_incomplete') + "`n`n" + $Markdown
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
        Set-IdsGroupResolver { param($Id) return (Get-IdsText -Key 'text.reference_name_unavailable_in_offline_set_arg0' -Arguments @{ arg0 = ($Id) }) }
        $Ctx.Filters = @{}; $Ctx.Categories = @{}; $Ctx.GroupObjects = @{}; $Ctx.GroupErrors = @{}
        return
    }
    Set-IdsProgress -State $Ctx.State -Percent 3 -Phase (Get-IdsText -Key 'text.loading_reference_data')

    $categories = @{}
    try {
        $cats = Invoke-IdsGraph -Path '/deviceManagement/configurationCategories?$select=id,displayName,parentCategoryId' -All -Tolerant
        foreach ($c in @($cats)) { if ($c -and $c.id) { $categories[$c.id] = $c } }
        Write-IdsLog -State $Ctx.State -Message (Get-IdsText -Key 'text.loaded_arg0_settings_catalog_categories' -Arguments @{ arg0 = ($categories.Count) })
    } catch { Add-IdsWarning $Ctx (Get-IdsText -Key 'text.could_not_load_settings_catalog_categories_arg0' -Arguments @{ arg0 = ($_.Exception.Message) }) }

    $filters = @{}
    try {
        # The rule is the point of a filter, so fetch it here rather than only the name:
        # assignments render the expression inline.
        $f = Invoke-IdsGraph -Path '/deviceManagement/assignmentFilters?$select=id,displayName,rule,platform,assignmentFilterManagementType' -All -Tolerant
        foreach ($x in @($f)) { if ($x -and $x.id) { $filters[$x.id] = $x } }
    } catch { Add-IdsWarning $Ctx (Get-IdsText -Key 'text.could_not_load_assignment_filters_arg0' -Arguments @{ arg0 = ($_.Exception.Message) }) }

    $tags = @{}
    try {
        $t = Invoke-IdsGraph -Path '/deviceManagement/roleScopeTags?$select=id,displayName' -All -Tolerant
        foreach ($x in @($t)) { if ($x -and $x.id) { $tags[[string]$x.id] = $x.displayName } }
    } catch { Add-IdsWarning $Ctx (Get-IdsText -Key 'text.could_not_load_scope_tags_arg0' -Arguments @{ arg0 = ($_.Exception.Message) }) }

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
                404 { return (Get-IdsText -Key 'text.deleted_group_arg0' -Arguments @{ arg0 = ($Id) }) }
                403 { return (Get-IdsText -Key 'text.group_arg0_insufficient_permission_to_read' -Arguments @{ arg0 = ($Id) }) }
                default { return (Get-IdsText -Key 'text.unresolved_group_arg0' -Arguments @{ arg0 = ($Id) }) }
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
    Set-IdsRenderOptions @{ UnknownSettings = $false }
    $collection = $Ctx.PolicySnapshot.collection
    if (-not $collection.documentation.ContainsKey($Family)) { throw (Get-IdsText -Key 'text.loaded_policy_family_is_unavailable_reload_policies') }
    if (@($collection.issues + $collection.documentationIssues | Where-Object family -EQ $Family).Count -or
        @($collection.sources | Where-Object { $_.family -eq $Family -and -not $_.complete }).Count -or
        @($collection.policies | Where-Object { $_.family -eq $Family -and -not $_.settingsComplete }).Count) {
        if ($Ctx.PolicySnapshot.source.kind -eq 'offline') {
            $Ctx.OfflineIncomplete = $true
            $Ctx.PreservePolicyPages = $true
            Set-IdsRenderOptions @{ UnknownSettings = $true }
            Add-IdsWarning $Ctx (Get-IdsText -Key 'text.arg0_has_incomplete_offline_evidence_existing_policy_pages_are_preserved_new_pages_explicitly_show_t' -Arguments @{ arg0 = ($Family) })
            return $collection.documentation[$Family]
        }
        # A partial inventory must never erase previously generated policy pages.
        throw (Get-IdsText -Key 'text.loaded_policy_evidence_is_incomplete_for_this_family_reload_policies_after_resolving_the_collection_')
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
                (Get-IdsText -Key 'text.policy_type')  = (Get-IdsText -Key 'text.settings_catalog')
                (Get-IdsText -Key 'text.platform')     = $platform
                (Get-IdsText -Key 'text.technologies') = $technologies
                (Get-IdsText -Key 'text.created')      = (Format-IdsDate $p.createdDateTime)
                (Get-IdsText -Key 'text.last_modified') = (Format-IdsDate $p.lastModifiedDateTime)
                (Get-IdsText -Key 'text.scope_tags')   = (Format-IdsScopeTags $p.roleScopeTagIds)
                (Get-IdsText -Key 'text.setting_count') = $p.settingCount
                (Get-IdsText -Key 'text.intune_id')    = $p.id
            }) `
            -Sections ([ordered]@{ (Get-IdsText -Key 'text.settings') = (Format-IdsSettingsCatalog -Settings $settings) }) `
            -Assignments $p.assignments `
            -Raw $p

        Save-IdsDoc -Ctx $Ctx -Section (Get-IdsText -Key 'text.settings_catalog') -Folder $folder -Title $name `
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
            $sections[(Get-IdsText -Key 'text.oma_uri_settings')] = (Format-IdsOmaSettings -OmaSettings $c.omaSettings)
        }
        if ($isCustom -and $c.PSObject.Properties['payload'] -and $c.payload) {
            if ($Ctx.Options.IncludeScriptContent) {
                $sections['Payload'] = "``````xml`n" + (ConvertFrom-IdsBase64 ([string]$c.payload)) + "`n``````"
            } else {
                $sections['Payload'] = (Get-IdsText -Key 'text.payload_omitted_script_and_payload_content_disabled_for_this_export')
            }
        }
        $sections[(Get-IdsText -Key 'text.settings')] = (Format-IdsTemplateSettings -Config $c)

        $md = New-IdsDocument `
            -Title $c.displayName -Description $c.description `
            -FrontMatter ([ordered]@{
                intuneId = $c.id; objectType = ($type -replace '#microsoft\.graph\.', '')
                lastModified = (Format-IdsDate $c.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                (Get-IdsText -Key 'text.profile_type')  = (Format-IdsOdataType $type)
                (Get-IdsText -Key 'text.created')       = (Format-IdsDate $c.createdDateTime)
                (Get-IdsText -Key 'text.last_modified') = (Format-IdsDate $c.lastModifiedDateTime)
                (Get-IdsText -Key 'text.version')       = $c.version
                (Get-IdsText -Key 'text.scope_tags')    = (Format-IdsScopeTags $c.roleScopeTagIds)
                (Get-IdsText -Key 'text.intune_id')     = $c.id
            }) `
            -Sections $sections -Assignments $c.assignments -Raw $c

        $label = (Get-IdsText -Key 'text.configuration_profiles')
        if ($isCustom) { $label = (Get-IdsText -Key 'text.custom_profiles') }
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
        } catch { Add-IdsWarning $Ctx (Get-IdsText -Key 'text.admx_values_for_arg0_arg1' -Arguments @{ arg0 = ($g.displayName); arg1 = ($_.Exception.Message) }) }
        }

        $md = New-IdsDocument `
            -Title $g.displayName -Description $g.description `
            -FrontMatter ([ordered]@{
                intuneId = $g.id; objectType = 'groupPolicyConfiguration'
                lastModified = (Format-IdsDate $g.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                (Get-IdsText -Key 'text.profile_type')  = (Get-IdsText -Key 'text.administrative_template_admx')
                (Get-IdsText -Key 'text.created')       = (Format-IdsDate $g.createdDateTime)
                (Get-IdsText -Key 'text.last_modified') = (Format-IdsDate $g.lastModifiedDateTime)
                (Get-IdsText -Key 'text.configured_settings') = @($defValues).Count
                (Get-IdsText -Key 'text.scope_tags')    = (Format-IdsScopeTags $g.roleScopeTagIds)
                (Get-IdsText -Key 'text.intune_id')     = $g.id
            }) `
            -Sections ([ordered]@{ (Get-IdsText -Key 'text.settings') = (Format-IdsAdmxSettings -DefinitionValues $defValues) }) `
            -Assignments $g.assignments -Raw $g

        Save-IdsDoc -Ctx $Ctx -Section (Get-IdsText -Key 'text.administrative_templates') -Folder 'configuration/administrative-templates' `
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
            (Get-IdsText -Key 'text.compliance_settings') = (Format-IdsTemplateSettings -Config $c)
            (Get-IdsText -Key 'text.actions_for_noncompliance') = (Format-IdsComplianceActions -ScheduledActions $c.scheduledActionsForRule)
        }
        $md = New-IdsDocument `
            -Title $c.displayName -Description $c.description `
            -FrontMatter ([ordered]@{
                intuneId = $c.id; objectType = ($t -replace '#microsoft\.graph\.', '')
                platform = $platform; lastModified = (Format-IdsDate $c.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                (Get-IdsText -Key 'text.policy_type')   = (Format-IdsOdataType $t)
                (Get-IdsText -Key 'text.platform')      = $platform
                (Get-IdsText -Key 'text.created')       = (Format-IdsDate $c.createdDateTime)
                (Get-IdsText -Key 'text.last_modified') = (Format-IdsDate $c.lastModifiedDateTime)
                (Get-IdsText -Key 'text.version')       = $c.version
                (Get-IdsText -Key 'text.scope_tags')    = (Format-IdsScopeTags $c.roleScopeTagIds)
                (Get-IdsText -Key 'text.intune_id')     = $c.id
            }) `
            -Sections $sections -Assignments $c.assignments -Raw $c

        Save-IdsDoc -Ctx $Ctx -Section (Get-IdsText -Key 'text.compliance_policies') -Folder "compliance/$platform" `
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
                (Get-IdsText -Key 'text.policy_type')   = (Get-IdsText -Key 'text.endpoint_security')
                (Get-IdsText -Key 'text.template')      = $(if ($tpl) { $tpl.displayName } else { $intent.templateId })
                (Get-IdsText -Key 'text.template_type') = $(if ($tpl) { $tpl.templateType } else { '-' })
                (Get-IdsText -Key 'text.platform')      = $(if ($tpl) { $tpl.platformType } else { '-' })
                (Get-IdsText -Key 'text.last_modified') = (Format-IdsDate $intent.lastModifiedDateTime)
                (Get-IdsText -Key 'text.scope_tags')    = (Format-IdsScopeTags $intent.roleScopeTagIds)
                (Get-IdsText -Key 'text.intune_id')     = $intent.id
            }) `
            -Sections ([ordered]@{ (Get-IdsText -Key 'text.settings') = (Format-IdsIntentSettings -Settings $settings) }) `
            -Assignments $intent.assignments -Raw $intent

        Save-IdsDoc -Ctx $Ctx -Section (Get-IdsText -Key 'text.endpoint_security') -Folder "endpoint-security/$category" `
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
        $sections = [ordered]@{ (Get-IdsText -Key 'text.application_details') = (Format-IdsAppInstallSettings -App $a) }
        if ($a.PSObject.Properties['detectionRules'] -and $a.detectionRules) {
            $sections[(Get-IdsText -Key 'text.detection_rules')] = (Format-IdsDetectionRules -Rules $a.detectionRules)
        }
        if ($a.PSObject.Properties['requirementRules'] -and $a.requirementRules) {
            $sections[(Get-IdsText -Key 'text.requirement_rules')] = (Format-IdsDetectionRules -Rules $a.requirementRules)
        }
        if ($a.PSObject.Properties['returnCodes'] -and $a.returnCodes) {
            $sections[(Get-IdsText -Key 'text.return_codes')] = New-IdsTable -Headers @((Get-IdsText -Key 'text.code'), (Get-IdsText -Key 'text.type')) -Rows @(
                foreach ($r in @($a.returnCodes)) { , @($r.returnCode, $r.type) })
        }
        $md = New-IdsDocument `
            -Title $a.displayName -Description $a.description `
            -FrontMatter ([ordered]@{
                intuneId = $a.id; objectType = ($type -replace '#microsoft\.graph\.', '')
                platform = $platform; lastModified = (Format-IdsDate $a.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                (Get-IdsText -Key 'text.app_type')      = (Format-IdsAppType $type)
                (Get-IdsText -Key 'text.publisher')     = $a.publisher
                (Get-IdsText -Key 'text.platform')      = $platform
                (Get-IdsText -Key 'text.created')       = (Format-IdsDate $a.createdDateTime)
                (Get-IdsText -Key 'text.last_modified') = (Format-IdsDate $a.lastModifiedDateTime)
                (Get-IdsText -Key 'text.published')     = $a.publishingState
                (Get-IdsText -Key 'text.scope_tags')    = (Format-IdsScopeTags $a.roleScopeTagIds)
                (Get-IdsText -Key 'text.intune_id')     = $a.id
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
        @{ path = '/deviceAppManagement/iosManagedAppProtections?$expand=assignments'; folder = 'app-management/app-protection/ios'; label = (Get-IdsText -Key 'text.app_protection_policies') }
        @{ path = '/deviceAppManagement/androidManagedAppProtections?$expand=assignments'; folder = 'app-management/app-protection/android'; label = (Get-IdsText -Key 'text.app_protection_policies') }
        @{ path = '/deviceAppManagement/windowsManagedAppProtections?$expand=assignments'; folder = 'app-management/app-protection/windows'; label = (Get-IdsText -Key 'text.app_protection_policies') }
        @{ path = '/deviceAppManagement/targetedManagedAppConfigurations?$expand=assignments'; folder = 'app-management/app-configuration/managed-apps'; label = (Get-IdsText -Key 'text.app_configuration_policies') }
        @{ path = '/deviceAppManagement/mobileAppConfigurations?$expand=assignments'; folder = 'app-management/app-configuration/managed-devices'; label = (Get-IdsText -Key 'text.app_configuration_policies') }
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
                    (Get-IdsText -Key 'text.policy_type')   = (Format-IdsOdataType $p.'@odata.type')
                    (Get-IdsText -Key 'text.created')       = (Format-IdsDate $p.createdDateTime)
                    (Get-IdsText -Key 'text.last_modified') = (Format-IdsDate $p.lastModifiedDateTime)
                    (Get-IdsText -Key 'text.intune_id')     = $p.id
                }) `
                -Sections ([ordered]@{ (Get-IdsText -Key 'text.settings') = (Format-IdsTemplateSettings -Config $p) }) `
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
        @{ path = '/deviceManagement/deviceManagementScripts'; folder = 'scripts/windows'; label = (Get-IdsText -Key 'text.scripts'); content = 'scriptContent'; lang = 'powershell' }
        @{ path = '/deviceManagement/deviceShellScripts'; folder = 'scripts/macos'; label = (Get-IdsText -Key 'text.scripts'); content = 'scriptContent'; lang = 'bash' }
        @{ path = '/deviceManagement/deviceCustomAttributeShellScripts'; folder = 'scripts/macos-custom-attributes'; label = (Get-IdsText -Key 'text.scripts'); content = 'scriptContent'; lang = 'bash' }
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
                    $sections['Script'] = (Get-IdsText -Key 'text.script_body_omitted_script_content_disabled_for_this_export')
                }
            }
            $md = New-IdsDocument `
                -Title $full.displayName -Description $full.description `
                -FrontMatter ([ordered]@{
                    intuneId = $full.id; objectType = 'deviceManagementScript'
                    lastModified = (Format-IdsDate $full.lastModifiedDateTime)
                }) `
                -Overview ([ordered]@{
                    (Get-IdsText -Key 'text.file_name')         = $full.fileName
                    (Get-IdsText -Key 'text.run_as_account')    = $full.runAsAccount
                    (Get-IdsText -Key 'text.run_as_32_bit')     = $full.runAs32Bit
                    (Get-IdsText -Key 'text.signature_check')   = $full.enforceSignatureCheck
                    (Get-IdsText -Key 'text.block_execution_notifications') = $full.blockExecutionNotifications
                    (Get-IdsText -Key 'text.created')           = (Format-IdsDate $full.createdDateTime)
                    (Get-IdsText -Key 'text.last_modified')     = (Format-IdsDate $full.lastModifiedDateTime)
                    (Get-IdsText -Key 'text.scope_tags')        = (Format-IdsScopeTags $full.roleScopeTagIds)
                    (Get-IdsText -Key 'text.intune_id')         = $full.id
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
            if ($det) { $sections[(Get-IdsText -Key 'text.detection_script')] = "``````powershell`n$det`n``````" }
            if ($rem) { $sections[(Get-IdsText -Key 'text.remediation_script')] = "``````powershell`n$rem`n``````" }
        } else {
            $sections[(Get-IdsText -Key 'text.scripts')] = (Get-IdsText -Key 'text.script_bodies_omitted_script_content_disabled_for_this_export')
        }
        $md = New-IdsDocument `
            -Title $full.displayName -Description $full.description `
            -FrontMatter ([ordered]@{
                intuneId = $full.id; objectType = 'deviceHealthScript'
                lastModified = (Format-IdsDate $full.lastModifiedDateTime)
            }) `
            -Overview ([ordered]@{
                (Get-IdsText -Key 'text.publisher')      = $full.publisher
                (Get-IdsText -Key 'text.version')        = $full.version
                (Get-IdsText -Key 'text.run_as_account') = $full.runAsAccount
                (Get-IdsText -Key 'text.run_as_32_bit')  = $full.runAs32Bit
                (Get-IdsText -Key 'text.signature_check') = $full.enforceSignatureCheck
                (Get-IdsText -Key 'text.created')        = (Format-IdsDate $full.createdDateTime)
                (Get-IdsText -Key 'text.last_modified')  = (Format-IdsDate $full.lastModifiedDateTime)
                (Get-IdsText -Key 'text.scope_tags')     = (Format-IdsScopeTags $full.roleScopeTagIds)
                (Get-IdsText -Key 'text.intune_id')      = $full.id
            }) `
            -Sections $sections -Assignments $s.assignments -Raw $full
        Save-IdsDoc -Ctx $Ctx -Section (Get-IdsText -Key 'text.remediations') -Folder 'scripts/remediations' `
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
                (Get-IdsText -Key 'text.configuration_type') = (Format-IdsOdataType $t)
                (Get-IdsText -Key 'text.priority')           = $c.priority
                (Get-IdsText -Key 'text.created')            = (Format-IdsDate $c.createdDateTime)
                (Get-IdsText -Key 'text.last_modified')      = (Format-IdsDate $c.lastModifiedDateTime)
                (Get-IdsText -Key 'text.version')            = $c.version
                (Get-IdsText -Key 'text.intune_id')          = $c.id
            }) `
            -Sections ([ordered]@{ (Get-IdsText -Key 'text.settings') = (Format-IdsTemplateSettings -Config $c) }) `
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
                (Get-IdsText -Key 'text.profile_type')      = (Format-IdsOdataType $p.'@odata.type')
                (Get-IdsText -Key 'text.device_name_template') = $p.deviceNameTemplate
                (Get-IdsText -Key 'text.join_type')         = $p.deviceType
                (Get-IdsText -Key 'text.hybrid_join_skip_connectivity_check') = $p.hybridAzureADJoinSkipConnectivityCheck
                (Get-IdsText -Key 'text.created')           = (Format-IdsDate $p.createdDateTime)
                (Get-IdsText -Key 'text.last_modified')     = (Format-IdsDate $p.lastModifiedDateTime)
                (Get-IdsText -Key 'text.intune_id')         = $p.id
            }) `
            -Sections ([ordered]@{ (Get-IdsText -Key 'text.out_of_box_experience') = (Format-IdsTemplateSettings -Config $p) }) `
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
            (Get-IdsText -Key 'text.rule') = ('```' + "`n" + (Format-IdsFilterRule -Rule ([string]$f.rule)) + "`n" + '```')
        }
        # Every assignment that references this filter, so the page answers "where is this used?"
        $usedBy = @($Ctx.Assign | Where-Object { $_.FilterId -eq $f.id } | Sort-Object Section, Object)
        $sections[(Get-IdsText -Key 'text.used_by')] = New-IdsTable -Headers @((Get-IdsText -Key 'text.area'), (Get-IdsText -Key 'text.object'), (Get-IdsText -Key 'text.group'), (Get-IdsText -Key 'text.mode')) -Rows @(
            foreach ($u in $usedBy) { , @($u.Section, "[$($u.Object)](../../$($u.Path))", $u.Group, $u.FilterMode) }
        ) -EmptyText (Get-IdsText -Key 'text.not_used_by_any_assignment')

        $md = New-IdsDocument `
            -Title $f.displayName -Description $f.description `
            -FrontMatter ([ordered]@{ intuneId = $f.id; objectType = 'assignmentFilter' }) `
            -Overview ([ordered]@{
                (Get-IdsText -Key 'text.platform')      = $f.platform
                (Get-IdsText -Key 'text.filter_type')   = $f.assignmentFilterManagementType
                (Get-IdsText -Key 'text.created')       = (Format-IdsDate $f.createdDateTime)
                (Get-IdsText -Key 'text.last_modified') = (Format-IdsDate $f.lastModifiedDateTime)
                (Get-IdsText -Key 'text.used_by')       = $usedBy.Count
                (Get-IdsText -Key 'text.intune_id')     = $f.id
            }) `
            -Sections $sections `
            -Assignments $null -Raw $f
        Save-IdsDoc -Ctx $Ctx -Section (Get-IdsText -Key 'text.assignment_filters') -Folder 'reference/filters' -Title $f.displayName `
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
            -Overview ([ordered]@{ (Get-IdsText -Key 'text.built_in') = $r.isBuiltIn; (Get-IdsText -Key 'text.intune_id') = $r.id }) `
            -Sections ([ordered]@{ (Get-IdsText -Key 'text.allowed_actions') = (New-IdsTable -Headers @((Get-IdsText -Key 'text.action')) -Rows @(foreach ($p in ($perms | Sort-Object -Unique)) { , @($p) })) }) `
            -Assignments $null -Raw $r
        Save-IdsDoc -Ctx $Ctx -Section (Get-IdsText -Key 'text.custom_roles') -Folder 'reference/roles' -Title $r.displayName `
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
        $type = (Get-IdsText -Key 'text.assigned_security_group')
        if ($g.PSObject.Properties['membershipRule'] -and $g.membershipRule) { $type = (Get-IdsText -Key 'text.dynamic_group') }
        $sections = [ordered]@{}
        if ($g.PSObject.Properties['membershipRule'] -and $g.membershipRule) {
            $sections[(Get-IdsText -Key 'text.membership_rule')] = ("```````n" + [string]$g.membershipRule + "`n``````")
        }
        $used = @($Ctx.Assign | Where-Object { $_.Group -eq $g.displayName } | Sort-Object Section, Object)
        $sections[(Get-IdsText -Key 'text.used_by')] = New-IdsTable -Headers @((Get-IdsText -Key 'text.area'), (Get-IdsText -Key 'text.object'), (Get-IdsText -Key 'text.mode')) -Rows @(
            foreach ($u in $used) { , @($u.Section, "[$($u.Object)](../../$($u.Path))", $u.Mode) })

        $md = New-IdsDocument `
            -Title $g.displayName -Description $g.description `
            -FrontMatter ([ordered]@{ entraGroupId = $g.id; objectType = 'group' }) `
            -Overview ([ordered]@{
                (Get-IdsText -Key 'text.group_type')       = $type
                (Get-IdsText -Key 'text.security_enabled') = $g.securityEnabled
                (Get-IdsText -Key 'text.mail_enabled')     = $g.mailEnabled
                (Get-IdsText -Key 'text.entra_group_id')   = $g.id
            }) `
            -Sections $sections -Assignments $null -Raw $g
        Save-IdsDoc -Ctx $Ctx -Section (Get-IdsText -Key 'text.groups') -Folder 'reference/groups' -Title $g.displayName `
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
        $byGroup += New-IdsTable -Headers @((Get-IdsText -Key 'text.area'), (Get-IdsText -Key 'text.object'), (Get-IdsText -Key 'text.mode'), (Get-IdsText -Key 'text.intent'), (Get-IdsText -Key 'text.filter')) -Rows @(
            foreach ($r in ($grp.Group | Sort-Object Section, Object)) {
                , @($r.Section, "[$($r.Object)](../$($r.Path))", (Format-IdsAssignmentMode $r.Mode), $r.Intent, $r.Filter)
            })
        $byGroup += ''
    }
    $doc = @((Get-IdsText -Key 'text.assignments_by_group'), '', (Get-IdsText -Key 'text.every_intune_object_targeted_at_each_entra_id_group'), '') + $byGroup
    $rel = 'assignments/by-group.md'
    $Ctx.Stats[(Write-IdsFile -Path (Join-Path $Ctx.Root 'assignments\by-group.md') -Content (($doc -join "`n").TrimEnd() + "`n"))]++
    [void]$Ctx.Written.Add($rel)

    $byObject = @((Get-IdsText -Key 'text.assignments_by_object'), '')
    foreach ($sec in ($all | Group-Object Section | Sort-Object Name)) {
        $byObject += "## $($sec.Name)"
        $byObject += ''
        $byObject += New-IdsTable -Headers @((Get-IdsText -Key 'text.object'), (Get-IdsText -Key 'text.included'), (Get-IdsText -Key 'text.excluded')) -Rows @(
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
    $un = @((Get-IdsText -Key 'text.unassigned_objects'), '',
        (Get-IdsText -Key 'text.these_objects_exist_in_the_tenant_but_target_no_group_they_are_candidates_for_clean_up'), '')
    $un += New-IdsTable -Headers @((Get-IdsText -Key 'text.area'), (Get-IdsText -Key 'text.object')) -Rows @(
        foreach ($r in $unassigned) { , @($r.Section, "[$($r.Object)](../$($r.Path))") }) -EmptyText (Get-IdsText -Key 'text.every_object_is_assigned')
    $rel3 = 'assignments/unassigned.md'
    $Ctx.Stats[(Write-IdsFile -Path (Join-Path $Ctx.Root 'assignments\unassigned.md') -Content (($un -join "`n").TrimEnd() + "`n"))]++
    [void]$Ctx.Written.Add($rel3)
}

function Write-IdsIndex {
    param($Ctx, [hashtable]$Meta)
    $lines = @((Get-IdsText -Key 'text.intune_configuration_documentation'), '')
    $lines += "$(Get-IdsText 'text.tenant'): **$($Meta.organization)**"
    $lines += ''
    $lines += "| $(Get-IdsText 'text.area') | $(Get-IdsText 'text.objects') |"
    $lines += '|---|---|'
    foreach ($k in $Ctx.Index.Keys) { $lines += "| $k | $(@($Ctx.Index[$k]).Count) |" }
    $lines += ''
    $lines += (Get-IdsText -Key 'text.reports')
    $lines += ''
    $lines += "- [$(Get-IdsText 'text.assignments_by_group')](assignments/by-group.md)"
    $lines += "- [$(Get-IdsText 'text.assignments_by_object')](assignments/by-object.md)"
    $lines += "- [$(Get-IdsText 'text.unassigned_objects')](assignments/unassigned.md)"
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
            $generatedLabel = [regex]::Escape((Get-IdsText 'text.generated'))
            $prev = Select-String -LiteralPath $readmePath -Pattern "^\| $generatedLabel \| (.+) \|$" | Select-Object -First 1
            if ($prev) { $generated = $prev.Matches[0].Groups[1].Value }
        } catch { }
    }

    $lines = @()
    $lines += (Get-IdsText -Key 'text.intune_configuration_documentation')
    $lines += ''
    $lines += (Get-IdsText -Key 'text.generated_by_intune_docs_studio_no_entra_id_app_registration_required')
    $lines += ''
    $lines += '| | |'
    $lines += '|---|---|'
    $lines += "| $(Get-IdsText 'text.tenant') | $($Meta.organization) |"
    $lines += "| $(Get-IdsText 'text.tenant_id') | $($Meta.tenantId) |"
    $lines += "| $(Get-IdsText 'text.exported_by') | $($Meta.account) |"
    $lines += "| $(Get-IdsText 'text.sign_in_method') | $($Meta.method) |"
    $lines += "| $(Get-IdsText 'text.generated') | $generated |"
    if ($Meta.policiesCapturedAt) {
        $capturedDate = if ((Get-IdsLocale) -eq 'en-GB') { $Meta.policiesCapturedAt } else { Format-IdsDate $Meta.policiesCapturedAt }
        $lines += "| $(Get-IdsText 'text.policies_loaded') | $capturedDate |"
    }
    $lines += "| $(Get-IdsText 'text.objects_documented') | $($Meta.totalObjects) |"
    $lines += ''
    $lines += (Get-IdsText -Key 'text.contents')
    $lines += ''
    $lines += "| $(Get-IdsText 'text.area') | $(Get-IdsText 'text.objects') |"
    $lines += '|---|---|'
    foreach ($k in $Ctx.Counts.Keys) { $lines += "| $k | $($Ctx.Counts[$k]) |" }
    $lines += ''
    $lines += (Get-IdsText -Key 'text.full_table_of_contents_index_md_index_md')
    $lines += (Get-IdsText -Key 'text.assignment_reports_by_group_assignments_by_group_md_by_object_assignments_by_object_md_unassigned_as')
    $lines += ''
    if (@($Ctx.Warnings).Count -gt 0) {
        $lines += (Get-IdsText -Key 'text.warnings')
        $lines += ''
        foreach ($w in $Ctx.Warnings) { $lines += "- $w" }
        $lines += ''
    }
    $lines += (Get-IdsText -Key 'text.how_this_is_produced')
    $lines += ''
    $lines += (Get-IdsText 'doc.export_explanation')
    $lines += ''
    $lines += (Get-IdsText 'doc.drift_explanation')
    $lines += ''
    if ($Ctx.Options.IncludeScriptContent) {
        $lines += (Get-IdsText -Key 'text.note_script_bodies_and_custom_payloads_are_included_in_this_export')
        $lines += (Get-IdsText -Key 'text.review_repository_access_accordingly')
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
            $lines += (Get-IdsText -Key 'text.sections')
            $lines += ''
            foreach ($s in $subs) { $lines += '- [' + ($s -replace '-', ' ') + '](' + $leaf + '/' + $s + '.md)' }
            $lines += ''
        }
        $files = @()
        if ($dirFiles.ContainsKey($dir)) { $files = @($dirFiles[$dir] | Sort-Object) }
        if ($files.Count -gt 0) {
            $lines += (Get-IdsText -Key 'text.pages')
            $lines += ''
            foreach ($f in $files) { $lines += '- [' + $f + '](' + $leaf + '/' + $f + '.md)' }
            $lines += ''
        }
        if ($subs.Count -eq 0 -and $files.Count -eq 0) { $lines += (Get-IdsText -Key 'text.no_items') }

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
        Write-IdsLog -State $Ctx.State -Message (Get-IdsText -Key 'text.skipping_clean_up_of_removed_objects_this_run_was_incomplete') -Level 'warn'
        # Preserve the previous manifest entries so nothing is orphaned or lost.
        foreach ($rel in $previous) { [void]$Ctx.Written.Add($rel) }
    } else {
        foreach ($rel in $previous) {
            if ($Ctx.Written.Contains($rel)) { continue }
            $full = Join-Path $Ctx.Root ($rel -replace '/', '\')
            if (Test-Path -LiteralPath $full) {
                Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
                $Ctx.Stats.deleted++
                Write-IdsLog -State $Ctx.State -Message (Get-IdsText -Key 'text.removed_arg0_no_longer_present_in_intune' -Arguments @{ arg0 = ($rel) })
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
    return (Get-IdsText -Key 'text.this_folder_already_contains_documentation_for_arg0_but_you_are_signed_in_to_arg1_exporting_here_wou' -Arguments @{ arg0 = ($whoFrom); arg1 = ($whoTo) })
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
        throw (Get-IdsText -Key 'text.git_arg0_failed_exit_arg1_arg2' -Arguments @{ arg0 = ($Arguments[0]); arg1 = ($exitCode); arg2 = ($text) })
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
            throw (Get-IdsText -Key 'text.enter_an_azure_devops_https_or_ssh_clone_url_without_embedded_credentials_query_strings_or_fragments')
        }
        if (-not $Options.GitCommit) { throw (Get-IdsText -Key 'text.enable_commit_to_git_or_push_to_remote_when_specifying_a_repository_url') }
    }
    if ($Options.GitCommit -or $Options.GitBranch) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw (Get-IdsText -Key 'text.git_was_not_found_on_path_install_git_for_windows_to_commit_or_publish_documentation') }
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
                throw (Get-IdsText -Key 'text.the_output_folder_is_not_empty_and_is_not_a_git_checkout_choose_an_empty_folder_to_clone_the_azure_d')
            }
            Invoke-IdsGitCommand -Arguments @('clone', '--origin', 'origin', '--', $url, $root) | Out-Null
            Write-IdsLog -State $Ctx.State -Message (Get-IdsText -Key 'text.cloned_the_documentation_repository')
        } elseif ($Ctx.Options.GitPush) {
            throw (Get-IdsText -Key 'text.no_git_repository_configured_enter_an_azure_devops_repository_url_or_select_a_checkout_with_a_config')
        } else {
            Invoke-IdsGitCommand -Arguments @('-C', $root, 'init', '--quiet') | Out-Null
            Write-IdsLog -State $Ctx.State -Message (Get-IdsText -Key 'text.initialised_a_new_git_repository')
        }
    }
    if (-not $url -and -not $Ctx.Options.GitPush -and -not $branch) { return }

    $status = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'status', '--porcelain', '--untracked-files=all')).Output
    if ($status) { throw (Get-IdsText -Key 'text.the_publishing_checkout_has_uncommitted_changes_commit_or_stash_them_before_exporting_so_unrelated_f') }
    foreach ($operation in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply', 'sequencer')) {
        $operationPath = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'rev-parse', '--git-path', $operation)).Output
        if (-not [IO.Path]::IsPathRooted($operationPath)) { $operationPath = Join-Path $root $operationPath }
        if (Test-Path -LiteralPath $operationPath) { throw (Get-IdsText -Key 'text.a_git_merge_rebase_or_cherry_pick_is_in_progress_complete_or_abort_it_before_exporting') }
    }
    $remotes = @((Invoke-IdsGitCommand -Arguments @('-C', $root, 'remote')).Output -split '\r?\n')
    if ($url) {
        if ($remotes -contains 'origin') {
            $existing = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'remote', 'get-url', 'origin')).Output
            if ((ConvertTo-IdsGitRemoteUrl -Url $existing) -cne (ConvertTo-IdsGitRemoteUrl -Url $url)) {
                throw (Get-IdsText -Key 'text.the_output_checkout_points_to_a_different_origin_choose_a_matching_checkout_or_an_empty_output_folde')
            }
            $pushUrls = (Invoke-IdsGitCommand -Arguments @('-C', $root, 'remote', 'get-url', '--push', '--all', 'origin')).Output
            if ((ConvertTo-IdsGitRemoteUrl -Url $pushUrls) -cne (ConvertTo-IdsGitRemoteUrl -Url $url)) { throw (Get-IdsText -Key 'text.the_origin_push_url_differs_from_the_selected_repository_correct_the_git_remote_configuration_before') }
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
                if ($remoteBranches) { throw (Get-IdsText -Key 'text.the_populated_remote_has_no_usable_default_branch_select_an_existing_target_branch_or_correct_the_re') }
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
        throw (Get-IdsText -Key 'text.no_git_remote_configured_enter_an_azure_devops_repository_url_or_configure_a_remote_in_the_output_ch')
    }
}

function Invoke-IdsGit {
    param($Ctx, [hashtable]$Meta)
    if (-not $Ctx.Options.GitCommit -and -not $Ctx.Options.GitPush) { return $null }

    Push-Location $Ctx.Root
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $Ctx.Root '.git'))) {
            Invoke-IdsGitCommand -Arguments @('init', '--quiet') | Out-Null
            Write-IdsLog -State $Ctx.State -Message (Get-IdsText -Key 'text.initialised_a_new_git_repository')
        }
        Invoke-IdsGitCommand -Arguments @('add', '-A') | Out-Null
        $status = (Invoke-IdsGitCommand -Arguments @('status', '--porcelain')).Output
        $msg = $Ctx.Options.GitMessage
        if (-not $msg) { $msg = (Get-IdsText -Key 'text.intune_configuration_export_arg0' -Arguments @{ arg0 = ($Meta.generated) }) }
        $result = @{ committed = $false; message = (Get-IdsText -Key 'text.no_changes'); pushed = $false }
        if ($status) {
            Invoke-IdsGitCommand -Arguments @('-c', 'user.name=Intune Docs Studio', '-c', 'user.email=intune-docs-studio@localhost',
                'commit', '-m', $msg, '--quiet') | Out-Null
            Write-IdsLog -State $Ctx.State -Message (Get-IdsText -Key 'text.committed_changes_arg0' -Arguments @{ arg0 = ($msg) })
            $result.committed = $true
            $result.message = $msg
        } else {
            Write-IdsLog -State $Ctx.State -Message (Get-IdsText -Key 'text.no_configuration_changes_since_the_last_export_nothing_to_commit')
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
                throw (Get-IdsText -Key 'text.no_unambiguous_push_destination_configure_an_upstream_branch_or_an_origin_remote')
            }
            $result.pushed = $true
            Write-IdsLog -State $Ctx.State -Message (Get-IdsText -Key 'text.pushed_to_remote')
        }
        return $result
    } finally { Pop-Location }
}

# --- Orchestrator -----------------------------------------------------------------------

function Get-IdsSectionCatalog {
    return [ordered]@{
        'settingsCatalog'   = @{ label = (Get-IdsText -Key 'text.settings_catalog'); fn = 'Export-IdsSettingsCatalog'; weight = 25 }
        'deviceConfigs'     = @{ label = (Get-IdsText -Key 'text.configuration_profiles'); fn = 'Export-IdsDeviceConfigurations'; weight = 10 }
        'admx'              = @{ label = (Get-IdsText -Key 'text.administrative_templates'); fn = 'Export-IdsAdministrativeTemplates'; weight = 10 }
        'compliance'        = @{ label = (Get-IdsText -Key 'text.compliance_policies'); fn = 'Export-IdsCompliance'; weight = 6 }
        'endpointSecurity'  = @{ label = (Get-IdsText -Key 'text.endpoint_security'); fn = 'Export-IdsEndpointSecurity'; weight = 10 }
        'apps'              = @{ label = 'Applications'; fn = 'Export-IdsApps'; weight = 15 }
        'appManagement'     = @{ label = (Get-IdsText -Key 'text.app_protection_configuration'); fn = 'Export-IdsAppManagementPolicies'; weight = 6 }
        'scripts'           = @{ label = (Get-IdsText -Key 'text.scripts'); fn = 'Export-IdsScripts'; weight = 6 }
        'remediations'      = @{ label = (Get-IdsText -Key 'text.remediations'); fn = 'Export-IdsRemediations'; weight = 5 }
        'enrollment'        = @{ label = (Get-IdsText -Key 'text.enrollment_autopilot'); fn = 'Export-IdsEnrollment'; weight = 5 }
        'reference'         = @{ label = (Get-IdsText -Key 'text.filters_roles'); fn = 'Export-IdsReference'; weight = 4 }
        'groups'            = @{ label = (Get-IdsText -Key 'text.groups'); fn = 'Export-IdsGroups'; weight = 4 }
    }
}

function Start-IdsExport {
    <#  Entry point used by both the dashboard runspace and the CLI. #>
    param([hashtable]$State, [hashtable]$Options, $PolicySnapshot, [string]$Locale = $(if ($Options.Locale) { $Options.Locale } else { Get-IdsLocale }))

    $previousLocale = Get-IdsLocale
    $Locale = Resolve-IdsLocale $Locale -Strict
    Set-IdsLocale $Locale
    $State.Export.locale = $Locale
    $State.Export.running = $true
    $State.Export.done = $false
    $State.Export.error = $null
    $State.Export.percent = 0
    $State.Export.summary = $null

    try {
        Assert-IdsGitOptions -Options $Options
        if ($PolicySnapshot.source.kind -eq 'offline' -and @($Options.Sections | Where-Object {
            $_ -notin @('settingsCatalog', 'deviceConfigs', 'admx', 'compliance', 'endpointSecurity')
        }).Count) { throw (Get-IdsText -Key 'text.offline_documentation_cannot_collect_apps_scripts_or_other_live_sections') }
        $root = $Options.OutputPath
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
        $root = (Resolve-Path -LiteralPath $root).Path

        Set-IdsRenderOptions -Options @{
            IncludeRaw           = [bool]$Options.IncludeRaw
            IncludeScriptContent = [bool]$Options.IncludeScriptContent
            FrontMatter          = [bool]$Options.FrontMatter
            UnknownSettings      = $false
        }

        $ctx = New-IdsContext -Root $root -Options $Options -State $State
        $ctx.PolicySnapshot = $PolicySnapshot
        Write-IdsLog -State $State -Message (Get-IdsText -Key 'text.output_folder_arg0' -Arguments @{ arg0 = ($root) })

        if ($Options.GitCommit) {
            Set-IdsProgress -State $State -Percent 1 -Phase (Get-IdsText -Key 'text.preparing_documentation_repository')
            Initialize-IdsGitRepository -Ctx $ctx
        }

        $conn = if ($PolicySnapshot) {
            if ($PolicySnapshot.source.kind -ne 'offline' -and
                (-not $State.Auth -or ($State.Auth.tenant_id -and $State.Auth.tenant_id -ne $PolicySnapshot.tenant.id))) {
                throw (Get-IdsText -Key 'text.loaded_policies_do_not_belong_to_the_current_tenant')
            }
            Write-IdsLog -State $State -Message (Get-IdsText -Key 'text.using_arg0_policies_collected_at_arg1' -Arguments @{ arg0 = ($PolicySnapshot.source.kind); arg1 = ($PolicySnapshot.capturedAt) })
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
            generated    = (Format-IdsDate (Get-Date))
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
            Write-IdsLog -State $State -Message (Get-IdsText -Key 'text.collecting_arg0' -Arguments @{ arg0 = ($sec.label) })
            try {
                $count = & $sec.fn -Ctx $ctx
                if ($null -eq $count) { $count = 0 }
                $ctx.Counts[$sec.label] = $count
                $meta.totalObjects += [int]$count
                Write-IdsLog -State $State -Message (Get-IdsText -Key 'text.arg0_arg1_object_s' -Arguments @{ arg0 = ($sec.label); arg1 = ($count) })
            } catch {
                $where = ''
                try {
                    $inv = $_.InvocationInfo
                    if ($inv) { $where = " [$($inv.ScriptName | Split-Path -Leaf):$($inv.ScriptLineNumber)]" }
                } catch { }
                Add-IdsWarning $ctx (Get-IdsText -Key 'text.arg0_failed_arg1_arg2' -Arguments @{ arg0 = ($sec.label); arg1 = ($_.Exception.Message); arg2 = ($where) })
                $ctx.Counts[$sec.label] = 0
                $failedSections += $sec.label
            }
            $done += $sec.weight
        }

        Set-IdsProgress -State $State -Percent 92 -Phase (Get-IdsText -Key 'text.building_reports')

        # Snapshot before the summary files are written, so "did anything change?" reflects
        # the tenant's objects rather than the report pages describing them.
        $contentChanged = ($ctx.Stats.created + $ctx.Stats.updated + $ctx.Stats.deleted) -gt 0

        # Surface systematic group-resolution problems: they change how the assignment
        # reports should be read, and usually point at a missing Group.Read.All grant.
        if ($ctx.GroupErrors -and $ctx.GroupErrors.Count -gt 0) {
            $forbidden = @($ctx.GroupErrors.Values | Where-Object { $_ -eq 403 }).Count
            $missing = @($ctx.GroupErrors.Values | Where-Object { $_ -eq 404 }).Count
            if ($forbidden -gt 0) {
                Add-IdsWarning $ctx (Get-IdsText -Key 'text.arg0_assignment_group_s_could_not_be_read_http_403_the_sign_in_lacks_group_read_all_so_those_assignm' -Arguments @{ arg0 = ($forbidden) })
            }
            if ($missing -gt 0) {
                Add-IdsWarning $ctx (Get-IdsText -Key 'text.arg0_assignment_group_s_no_longer_exist_in_entra_id_http_404_those_assignments_target_deleted_groups' -Arguments @{ arg0 = ($missing) })
            }
        }

        Write-IdsAssignmentReports -Ctx $ctx
        Write-IdsIndex -Ctx $ctx -Meta $meta
        Write-IdsReadme -Ctx $ctx -Meta $meta -ContentChanged $contentChanged
        Write-IdsRepoFiles -Ctx $ctx
        Write-IdsNavigation -Ctx $ctx

        Set-IdsProgress -State $State -Percent 96 -Phase (Get-IdsText -Key 'text.pruning_removed_objects')
        Remove-IdsStaleFiles -Ctx $ctx -Complete ($failedSections.Count -eq 0 -and -not $ctx.OfflineIncomplete)

        $git = $null
        if ($Options.GitCommit) {
            Set-IdsProgress -State $State -Percent 98 -Phase (Get-IdsText -Key 'text.committing_to_git')
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
        Set-IdsProgress -State $State -Percent 100 -Phase (Get-IdsText -Key 'text.complete')
        Write-IdsLog -State $State -Message (Get-IdsText -Key 'text.done_arg0_created_arg1_updated_arg2_unchanged_arg3_removed' -Arguments @{ arg0 = ($ctx.Stats.created); arg1 = ($ctx.Stats.updated); arg2 = ($ctx.Stats.unchanged); arg3 = ($ctx.Stats.deleted) })
    } catch {
        $State.Export.error = $_.Exception.Message
        Write-IdsLog -State $State -Message (Get-IdsText -Key 'text.export_failed_arg0' -Arguments @{ arg0 = ($_.Exception.Message) }) -Level 'error'
    } finally {
        $State.Export.running = $false
        $State.Export.done = $true
        Set-IdsLocale $previousLocale
    }
}
