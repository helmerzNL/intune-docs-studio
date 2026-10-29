<#
    Render.ps1 — Graph objects to Git-friendly Markdown.

    Determinism is a first-class requirement: a re-run against an unchanged tenant must
    produce byte-identical files so that `git diff` shows genuine configuration drift and
    nothing else. That means no export timestamps inside object pages, sorted JSON keys and
    stable ordering everywhere.
#>

$script:IdsCategoryMap = @{}
$script:IdsGroupMap    = @{}
$script:IdsFilterMap   = @{}
$script:IdsScopeTagMap = @{}
$script:IdsOptions     = @{ IncludeRaw = $true; IncludeScriptContent = $true; FrontMatter = $true }

function Set-IdsRenderOptions {
    param([hashtable]$Options)
    foreach ($k in $Options.Keys) { $script:IdsOptions[$k] = $Options[$k] }
}
function Get-IdsRenderOptions { return $script:IdsOptions }

# --- Primitives -------------------------------------------------------------------------

function New-IdsSlug {
    <#  Stable, filesystem- and wiki-safe file name. Collisions are resolved by the caller
        appending a short id fragment, never by silent overwrite. #>
    param([string]$Text, [int]$MaxLength = 80)
    if (-not $Text) { return 'unnamed' }
    $s = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $s = $sb.ToString()
    $s = $s -replace '[^\p{L}\p{Nd}]+', '-'
    $s = $s -replace '-+', '-'
    $s = $s.Trim('-').ToLowerInvariant()
    if (-not $s) { $s = 'unnamed' }
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength).Trim('-') }
    # Reserved Windows device names would break the checkout on Windows agents.
    if ($s -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])$') { $s = $s + '-item' }
    return $s
}

function Get-IdsShortId {
    param([string]$Id)
    if (-not $Id) { return '' }
    return ($Id -replace '[^0-9a-fA-F]', '').ToLowerInvariant().PadRight(8, '0').Substring(0, 8)
}

function ConvertTo-IdsSortedObject {
    <#  Recursively rebuilds an object with alphabetically sorted keys and volatile Graph
        metadata removed, so serialised JSON is byte-stable across runs. #>
    param($InputObject, [int]$Depth = 0)
    if ($Depth -gt 25 -or $null -eq $InputObject) { return $InputObject }

    if ($InputObject -is [string] -or $InputObject -is [bool] -or $InputObject -is [int] -or
        $InputObject -is [long] -or $InputObject -is [double] -or $InputObject -is [datetime]) {
        return $InputObject
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in ($InputObject.Keys | Sort-Object)) {
            if ($k -like '*@odata.context' -or $k -like '*@odata.count') { continue }
            $out[$k] = ConvertTo-IdsSortedObject -InputObject $InputObject[$k] -Depth ($Depth + 1)
        }
        return $out
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $arr = @()
        foreach ($i in $InputObject) { $arr += , (ConvertTo-IdsSortedObject -InputObject $i -Depth ($Depth + 1)) }
        # Comma operator prevents PowerShell unrolling a single-element array on return,
        # which would silently turn ["0"] into "0" in the exported JSON.
        return , $arr
    }
    if ($InputObject.PSObject -and $InputObject.PSObject.Properties) {
        $out = [ordered]@{}
        foreach ($p in ($InputObject.PSObject.Properties | Sort-Object Name)) {
            if ($p.Name -like '*@odata.context' -or $p.Name -like '*@odata.count') { continue }
            $out[$p.Name] = ConvertTo-IdsSortedObject -InputObject $p.Value -Depth ($Depth + 1)
        }
        return $out
    }
    return $InputObject
}

function ConvertTo-IdsJson {
    param($InputObject, [int]$Depth = 25)
    $sorted = ConvertTo-IdsSortedObject -InputObject $InputObject
    return ($sorted | ConvertTo-Json -Depth $Depth)
}

function Format-IdsCell {
    <#  Escapes a value for use inside a Markdown table cell. #>
    param($Value, [int]$MaxLength = 400, [switch]$PlainText)
    if ($null -eq $Value) { return '-' }
    if ($Value -is [bool]) { if ($Value) { return 'Yes' } else { return 'No' } }
    if ($Value -is [array]) {
        if ($Value.Count -eq 0) { return '-' }
        $Value = ($Value | ForEach-Object { [string]$_ }) -join ', '
    }
    if ($Value -isnot [string]) {
        if ($Value -is [datetime]) { $Value = $Value.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC' }
        else { $Value = [string]$Value }
    }
    if ($Value -eq '') { return '-' }
    if ($PlainText) {
        if ($Value.Length -gt $MaxLength) { return $Value.Substring(0, $MaxLength) + '…' }
        return $Value
    }
    $t = $Value -replace '\|', '\|'
    $t = $t -replace "`r`n", '<br>'
    $t = $t -replace "`n", '<br>'
    $t = $t -replace "`r", '<br>'
    if ($t.Length -gt $MaxLength) { $t = $t.Substring(0, $MaxLength) + '…' }
    return $t
}

function Format-IdsDate {
    param($Value)
    if (-not $Value) { return '-' }
    try { return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC' } catch { return [string]$Value }
}

function Format-IdsBytes {
    param($Bytes)
    if ($null -eq $Bytes -or $Bytes -eq 0) { return '-' }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function ConvertFrom-IdsBase64 {
    param([string]$Value)
    if (-not $Value) { return '' }
    try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value)) } catch { return '' }
}

function Format-IdsOdataType {
    param([string]$Type)
    if (-not $Type) { return 'unknown' }
    $s = $Type -replace '#microsoft\.graph\.', ''
    $s = $s -creplace '([a-z0-9])([A-Z])', '$1 $2'
    if ($s.Length -gt 0) { $s = $s.Substring(0, 1).ToUpperInvariant() + $s.Substring(1) }
    return $s
}

function New-IdsTable {
    <#  Builds a Markdown table from an ordered dictionary or an array of rows. #>
    param(
        [string[]]$Headers,
        [object[]]$Rows,
        [string]$EmptyText = '_None_',
        [switch]$AsData,
        [string]$Title = ''
    )
    if ($AsData) {
        return [pscustomobject]@{
            title = $Title; headers = @($Headers)
            rows = @(foreach ($r in $Rows) {
                [pscustomobject]@{ cells = @(foreach ($c in $r) { Format-IdsCell $c -PlainText }) }
            })
        }
    }
    if (-not $Rows -or $Rows.Count -eq 0) { return $EmptyText }
    $out = @()
    $out += '| ' + ($Headers -join ' | ') + ' |'
    $out += '|' + (($Headers | ForEach-Object { '---' }) -join '|') + '|'
    foreach ($r in $Rows) {
        $cells = foreach ($c in $r) { Format-IdsCell $c }
        $out += '| ' + ($cells -join ' | ') + ' |'
    }
    return ($out -join "`n")
}

function New-IdsPropertyTable {
    param([System.Collections.IDictionary]$Properties, [string]$EmptyText = '_None_')
    $rows = @()
    foreach ($k in $Properties.Keys) {
        $v = $Properties[$k]
        if ($null -eq $v -or ($v -is [string] -and $v -eq '')) { continue }
        $rows += , @($k, (Format-IdsCell $v))
    }
    return (New-IdsTable -Headers @('Property', 'Value') -Rows $rows -EmptyText $EmptyText)
}

# --- Lookup maps ------------------------------------------------------------------------

function Set-IdsLookupMaps {
    param([hashtable]$Groups, [hashtable]$Filters, [hashtable]$ScopeTags, [hashtable]$Categories)
    if ($Groups)     { $script:IdsGroupMap = $Groups }
    if ($Filters)    { $script:IdsFilterMap = $Filters }
    if ($ScopeTags)  { $script:IdsScopeTagMap = $ScopeTags }
    if ($Categories) { $script:IdsCategoryMap = $Categories }
}

$script:IdsGroupResolver = $null

function Set-IdsGroupResolver {
    <#  Lets the exporter supply a lazy lookup so group display names are available at the
        moment a page is rendered, without enumerating every group in the directory. #>
    param([scriptblock]$Resolver)
    $script:IdsGroupResolver = $Resolver
}

function Resolve-IdsGroup {
    param([string]$Id)
    if (-not $Id) { return '-' }
    if ($script:IdsGroupMap.ContainsKey($Id)) { return $script:IdsGroupMap[$Id] }
    if ($script:IdsGroupResolver) {
        try {
            $name = & $script:IdsGroupResolver $Id
            if ($name) { $script:IdsGroupMap[$Id] = $name; return $name }
        } catch { }
    }
    $script:IdsGroupMap[$Id] = "(unresolved group $Id)"
    return $script:IdsGroupMap[$Id]
}
function Resolve-IdsFilterObject {
    <#  Returns the full filter definition so callers can show its rule, not merely its name.
        The map holds whole objects; older callers that only want a name use Resolve-IdsFilter. #>
    param([string]$Id)
    if (-not $Id) { return $null }
    if ($script:IdsFilterMap.ContainsKey($Id)) { return $script:IdsFilterMap[$Id] }
    return $null
}

function Resolve-IdsFilter {
    param([string]$Id)
    if (-not $Id) { return $null }
    $f = Resolve-IdsFilterObject -Id $Id
    if ($f) {
        if ($f -is [string]) { return $f }
        if ($f.PSObject.Properties['displayName'] -and $f.displayName) { return [string]$f.displayName }
    }
    return "(filter $Id)"
}
function Resolve-IdsScopeTag {
    param([string]$Id)
    if (-not $Id) { return $null }
    if ($script:IdsScopeTagMap.ContainsKey($Id)) { return $script:IdsScopeTagMap[$Id] }
    return "(tag $Id)"
}

function Format-IdsScopeTags {
    param($Ids)
    if (-not $Ids -or @($Ids).Count -eq 0) { return 'Default' }
    return (@($Ids | ForEach-Object { Resolve-IdsScopeTag ([string]$_) }) -join ', ')
}

# --- Assignments ------------------------------------------------------------------------

function ConvertTo-IdsAssignmentRows {
    <#  Normalises Graph assignment objects into flat rows. Shared by the object pages and
        the tenant-wide assignment matrix. #>
    param($Assignments)
    $rows = @()
    foreach ($a in @($Assignments)) {
        if (-not $a) { continue }
        $tgt = $a.target
        if (-not $tgt) { continue }
        $type = [string]$tgt.'@odata.type'
        $group = ''
        $mode = 'Included'
        switch -Wildcard ($type) {
            '*allDevicesAssignmentTarget'       { $group = 'All devices' }
            '*allLicensedUsersAssignmentTarget' { $group = 'All users' }
            '*exclusionGroupAssignmentTarget'   { $group = (Resolve-IdsGroup $tgt.groupId); $mode = 'Excluded' }
            '*groupAssignmentTarget'            { $group = (Resolve-IdsGroup $tgt.groupId) }
            default                             { $group = (Format-IdsOdataType $type) }
        }
        $filter = $null; $filterMode = $null; $filterId = $null; $filterRule = $null
        if ($tgt.PSObject.Properties['deviceAndAppManagementAssignmentFilterId'] -and $tgt.deviceAndAppManagementAssignmentFilterId) {
            $filterId = [string]$tgt.deviceAndAppManagementAssignmentFilterId
            $filter = Resolve-IdsFilter $filterId
            $filterMode = $tgt.deviceAndAppManagementAssignmentFilterType
            $fo = Resolve-IdsFilterObject -Id $filterId
            if ($fo -and $fo -isnot [string] -and $fo.PSObject.Properties['rule']) { $filterRule = [string]$fo.rule }
        }
        # Graph reports "none" when no filter is attached; treat that as no filter at all.
        if ($filterMode -and [string]$filterMode -eq 'none' -and -not $filterId) { $filterMode = $null }
        $intent = $null
        if ($a.PSObject.Properties['intent'] -and $a.intent) { $intent = $a.intent }
        $rows += , [pscustomobject]@{
            Mode       = $mode
            Group      = $group
            GroupId    = $(if ($tgt.PSObject.Properties['groupId']) { $tgt.groupId } else { $null })
            Filter     = $filter
            FilterId   = $filterId
            FilterMode = $filterMode
            FilterRule = $filterRule
            Intent     = $intent
        }
    }
    return ($rows | Sort-Object Mode, Group)
}

function Format-IdsFilterRule {
    <#  Presents a filter rule readably. Intune writes these as a single long line; splitting
        on the top-level boolean operators makes a real expression legible without altering it. #>
    param([string]$Rule)
    if (-not $Rule) { return '' }
    $text = $Rule.Trim()
    if ($text.Length -le 60) { return $text }

    $lines = @()
    $current = ''
    $depth = 0
    $inQuote = $false
    $i = 0
    while ($i -lt $text.Length) {
        $ch = $text[$i]
        if ($ch -eq '"') { $inQuote = -not $inQuote }
        elseif (-not $inQuote) {
            if ($ch -eq '(') { $depth++ }
            elseif ($ch -eq ')') { $depth-- }
            elseif ($depth -eq 0 -and $ch -eq ' ') {
                # Break before a top-level "and" / "or" so each clause sits on its own line.
                $rest = $text.Substring($i + 1)
                if ($rest -match '^(and|or)\s') {
                    $op = $Matches[1]
                    if ($current.Trim()) { $lines += $current.Trim() }
                    $current = "$op "
                    $i += $op.Length + 2
                    continue
                }
            }
        }
        $current += $ch
        $i++
    }
    if ($current.Trim()) { $lines += $current.Trim() }
    if ($lines.Count -le 1) { return $text }
    return ($lines -join "`n")
}

function Format-IdsAssignments {
    param($Assignments)
    $rows = ConvertTo-IdsAssignmentRows -Assignments $Assignments
    if (-not $rows -or $rows.Count -eq 0) { return '> **Not assigned.** This object exists in the tenant but targets no group.' }

    $hasIntent = ($rows | Where-Object { $_.Intent }).Count -gt 0
    $included = @($rows | Where-Object { $_.Mode -eq 'Included' })
    $excluded = @($rows | Where-Object { $_.Mode -eq 'Excluded' })

    $out = @()
    $out += '**Included**'
    $out += ''
    if ($hasIntent) {
        $out += New-IdsTable -Headers @('Group', 'Intent', 'Filter', 'Filter mode') -Rows @(
            foreach ($r in $included) { , @($r.Group, $r.Intent, $r.Filter, $r.FilterMode) })
    } else {
        $out += New-IdsTable -Headers @('Group', 'Filter', 'Filter mode') -Rows @(
            foreach ($r in $included) { , @($r.Group, $r.Filter, $r.FilterMode) })
    }
    $out += ''
    $out += '**Excluded**'
    $out += ''
    $out += New-IdsTable -Headers @('Group', 'Filter', 'Filter mode') -Rows @(
        foreach ($r in $excluded) { , @($r.Group, $r.Filter, $r.FilterMode) })

    # Spell out every filter this object uses. A rule is what actually decides which devices
    # are targeted, so reading the assignment without it tells you very little — and a rule
    # is far too long to sit in a table cell.
    $used = @($rows | Where-Object { $_.FilterId } | Sort-Object Filter -Unique)
    if ($used.Count -gt 0) {
        $out += ''
        $out += '**Filters used**'
        $out += ''
        foreach ($f in $used) {
            $modes = @($rows | Where-Object { $_.FilterId -eq $f.FilterId } | ForEach-Object { $_.FilterMode } | Where-Object { $_ } | Sort-Object -Unique)
            $modeText = ''
            if ($modes.Count -gt 0) { $modeText = ' — mode: ' + ($modes -join ', ') }
            $out += "*$($f.Filter)*$modeText"
            $out += ''
            if ($f.FilterRule) {
                $out += '```'
                $out += (Format-IdsFilterRule -Rule $f.FilterRule)
                $out += '```'
            } else {
                $out += '_Rule not available._'
            }
            $out += ''
        }
    }
    return (($out -join "`n").TrimEnd())
}

# --- Settings catalog -------------------------------------------------------------------

function New-IdsDefinitionMap {
    <#  Builds settingDefinitionId -> definition from the settingDefinitions collections that
        Graph returns when settings are requested with $expand=settingDefinitions. This turns
        what used to be one HTTP call per setting into zero extra calls. #>
    param($Settings)
    $map = @{}
    foreach ($s in @($Settings)) {
        if (-not $s) { continue }
        if ($s.PSObject.Properties['settingDefinitions']) {
            foreach ($d in @($s.settingDefinitions)) {
                if ($d -and $d.id -and -not $map.ContainsKey($d.id)) { $map[$d.id] = $d }
            }
        }
    }
    return $map
}

function Get-IdsCategoryPath {
    param([string]$Id, [int]$Depth = 0)
    if (-not $Id -or $Depth -gt 10) { return '' }
    if (-not $script:IdsCategoryMap.ContainsKey($Id)) { return '' }
    $c = $script:IdsCategoryMap[$Id]
    $name = $c.displayName
    if ($c.parentCategoryId -and $c.parentCategoryId -ne $Id) {
        $parent = Get-IdsCategoryPath -Id $c.parentCategoryId -Depth ($Depth + 1)
        if ($parent) { return "$parent > $name" }
    }
    return $name
}

function Get-IdsPrettyId {
    param([string]$Id)
    if (-not $Id) { return '(unnamed)' }
    $last = $Id.Split('_')[-1]
    $words = $last -creplace '([a-z0-9])([A-Z])', '$1 $2'
    if ($words.Length -gt 0) { $words = $words.Substring(0, 1).ToUpperInvariant() + $words.Substring(1) }
    return $words
}

function Get-IdsSettingName {
    param($DefMap, [string]$Id)
    if ($DefMap -and $DefMap.ContainsKey($Id)) {
        $d = $DefMap[$Id]
        if ($d.PSObject.Properties['displayName'] -and $d.displayName) { return $d.displayName }
        if ($d.PSObject.Properties['name'] -and $d.name) { return $d.name }
    }
    return (Get-IdsPrettyId $Id)
}

function Get-IdsSettingCategory {
    param($DefMap, [string]$Id)
    if (-not $DefMap -or -not $DefMap.ContainsKey($Id)) { return '' }
    $d = $DefMap[$Id]
    if ($d.PSObject.Properties['categoryId'] -and $d.categoryId) { return (Get-IdsCategoryPath -Id $d.categoryId) }
    return ''
}

function Get-IdsOptionText {
    param($DefMap, [string]$DefId, $Value)
    $v = [string]$Value
    if ($DefMap -and $DefMap.ContainsKey($DefId)) {
        $d = $DefMap[$DefId]
        if ($d.PSObject.Properties['options'] -and $d.options) {
            foreach ($o in @($d.options)) {
                $ov = $null
                if ($o.PSObject.Properties['optionValue'] -and $o.optionValue) { $ov = [string]$o.optionValue.value }
                if ($o.itemId -eq $v -or $ov -eq $v -or $o.name -eq $v) {
                    if ($o.displayName) { return $o.displayName }
                }
            }
        }
    }
    if ($v -and $DefId -and $v.StartsWith($DefId + '_')) { return (Get-IdsPrettyId $v.Substring($DefId.Length + 1)) }
    return $v
}

function Expand-IdsSettingInstance {
    <#  Flattens a (deeply nested) settings-catalog instance into Category/Setting/Value rows. #>
    param($Instance, $DefMap, [string]$ParentName = '', [int]$Depth = 0)
    $rows = @()
    if (-not $Instance -or $Depth -gt 15) { return $rows }

    $defId = [string]$Instance.settingDefinitionId
    $type = [string]$Instance.'@odata.type'
    $name = Get-IdsSettingName -DefMap $DefMap -Id $defId
    $cat = Get-IdsSettingCategory -DefMap $DefMap -Id $defId
    $full = $name
    if ($ParentName) { $full = "$ParentName / $name" }

    switch -Wildcard ($type) {
        '*choiceSettingInstance' {
            $val = $null
            if ($Instance.choiceSettingValue) { $val = $Instance.choiceSettingValue.value }
            $rows += , [pscustomobject]@{ Category = $cat; Setting = $full; Value = (Get-IdsOptionText -DefMap $DefMap -DefId $defId -Value $val) }
            if ($Instance.choiceSettingValue -and $Instance.choiceSettingValue.children) {
                foreach ($c in @($Instance.choiceSettingValue.children)) {
                    $rows += Expand-IdsSettingInstance -Instance $c -DefMap $DefMap -ParentName $full -Depth ($Depth + 1)
                }
            }
        }
        '*simpleSettingInstance' {
            $sv = $Instance.simpleSettingValue
            $val = ''
            if ($sv) {
                if ($sv.PSObject.Properties['value']) { $val = $sv.value }
                else { $val = (ConvertTo-Json $sv -Depth 5 -Compress) }
                if ([string]$sv.'@odata.type' -like '*SecretSettingValue*') { $val = '«secret — not exported»' }
            }
            $rows += , [pscustomobject]@{ Category = $cat; Setting = $full; Value = $val }
        }
        '*choiceSettingCollectionInstance' {
            $vals = @()
            foreach ($cv in @($Instance.choiceSettingCollectionValue)) {
                $vals += (Get-IdsOptionText -DefMap $DefMap -DefId $defId -Value $cv.value)
                if ($cv.children) {
                    foreach ($c in @($cv.children)) {
                        $rows += Expand-IdsSettingInstance -Instance $c -DefMap $DefMap -ParentName $full -Depth ($Depth + 1)
                    }
                }
            }
            $rows += , [pscustomobject]@{ Category = $cat; Setting = $full; Value = ($vals -join ', ') }
        }
        '*simpleSettingCollectionInstance' {
            $vals = @(@($Instance.simpleSettingCollectionValue) | ForEach-Object { $_.value })
            $rows += , [pscustomobject]@{ Category = $cat; Setting = $full; Value = ($vals -join ', ') }
        }
        '*groupSettingCollectionInstance' {
            $i = 0
            foreach ($g in @($Instance.groupSettingCollectionValue)) {
                $i++
                $label = $full
                if (@($Instance.groupSettingCollectionValue).Count -gt 1) { $label = "$full [$i]" }
                foreach ($c in @($g.children)) {
                    $rows += Expand-IdsSettingInstance -Instance $c -DefMap $DefMap -ParentName $label -Depth ($Depth + 1)
                }
            }
        }
        '*groupSettingInstance' {
            if ($Instance.groupSettingValue -and $Instance.groupSettingValue.children) {
                foreach ($c in @($Instance.groupSettingValue.children)) {
                    $rows += Expand-IdsSettingInstance -Instance $c -DefMap $DefMap -ParentName $full -Depth ($Depth + 1)
                }
            }
        }
        default {
            $rows += , [pscustomobject]@{ Category = $cat; Setting = $full; Value = (ConvertTo-Json $Instance -Depth 4 -Compress) }
        }
    }
    return $rows
}

function Format-IdsSettingsCatalog {
    param($Settings, [switch]$AsData)
    if (-not $Settings -or @($Settings).Count -eq 0) {
        if ($AsData) { return }
        return '_No settings configured._'
    }
    $defMap = New-IdsDefinitionMap -Settings $Settings
    $rows = @()
    foreach ($s in @($Settings)) {
        if ($s.PSObject.Properties['settingInstance'] -and $s.settingInstance) {
            $rows += Expand-IdsSettingInstance -Instance $s.settingInstance -DefMap $defMap
        }
    }
    if ($rows.Count -eq 0) {
        if ($AsData) { return }
        return '_No settings configured._'
    }

    $out = @()
    $grouped = $rows | Group-Object Category | Sort-Object Name
    foreach ($g in $grouped) {
        $title = $g.Name
        if (-not $title) { $title = 'General' }
        if ($AsData) {
            New-IdsTable -Title $title -Headers @('Setting', 'Value') -AsData -Rows @(
                foreach ($r in ($g.Group | Sort-Object Setting)) { , @($r.Setting, $r.Value) })
            continue
        }
        $out += "**$title**"
        $out += ''
        $out += New-IdsTable -Headers @('Setting', 'Value') -Rows @(
            foreach ($r in ($g.Group | Sort-Object Setting)) { , @($r.Setting, $r.Value) })
        $out += ''
    }
    if ($AsData) { return }
    $out += "_$($rows.Count) settings configured._"
    return ($out -join "`n")
}

# --- Legacy / template profiles ---------------------------------------------------------

function Format-IdsOmaSettings {
    param($OmaSettings, [switch]$AsData)
    if (-not $OmaSettings -or @($OmaSettings).Count -eq 0) { return $null }
    $rows = @()
    foreach ($o in @($OmaSettings | Sort-Object omaUri)) {
        if (-not $o) { continue }
        $val = '-'
        if ($o.PSObject.Properties['secretReferenceValueId'] -and $o.secretReferenceValueId) {
            $val = '«secret — not exported»'
        } elseif ($o.PSObject.Properties['value']) {
            $val = $o.value
            if ([string]$o.'@odata.type' -like '*OmaSettingStringXml*') { $val = ConvertFrom-IdsBase64 ([string]$val) }
        }
        $rows += , @($o.displayName, $o.omaUri, (Format-IdsOdataType $o.'@odata.type'), $val)
    }
    return (New-IdsTable -Headers @('Name', 'OMA-URI', 'Data type', 'Value') -Rows $rows -AsData:$AsData)
}

function Format-IdsTemplateSettings {
    <#  Legacy deviceConfiguration objects carry their settings as ordinary top-level
        properties. We render every configured scalar, skipping envelope noise. #>
    param($Config, [switch]$AsData)
    $skip = @('id', 'displayName', 'description', 'createdDateTime', 'lastModifiedDateTime', 'version',
        'roleScopeTagIds', 'supportsScopeTags', 'assignments', 'omaSettings', '@odata.type',
        'deviceManagementApplicabilityRuleOsEdition', 'deviceManagementApplicabilityRuleOsVersion',
        'deviceManagementApplicabilityRuleDeviceMode')
    $rows = @()
    foreach ($p in ($Config.PSObject.Properties | Sort-Object Name)) {
        if ($skip -contains $p.Name) { continue }
        if ($p.Name -like '*@odata*') { continue }
        $v = $p.Value
        if ($null -eq $v) { continue }
        if ($v -is [string] -and $v -eq '') { continue }
        if ($v -is [array] -and $v.Count -eq 0) { continue }
        if ($v -isnot [string] -and $v -isnot [bool] -and $v -isnot [int] -and $v -isnot [long] -and $v -isnot [double] -and $v -isnot [array]) {
            $v = (ConvertTo-Json $v -Depth 6 -Compress)
        }
        $label = ($p.Name -creplace '([a-z0-9])([A-Z])', '$1 $2')
        $label = $label.Substring(0, 1).ToUpperInvariant() + $label.Substring(1)
        $rows += , @($label, $v)
    }
    return (New-IdsTable -Headers @('Setting', 'Value') -Rows $rows -EmptyText '_No settings configured._' -AsData:$AsData)
}

function Format-IdsAdmxSettings {
    param($DefinitionValues, [switch]$AsData)
    if (-not $DefinitionValues -or @($DefinitionValues).Count -eq 0) {
        if ($AsData) { return }
        return '_No ADMX settings configured._'
    }
    $rows = @()
    foreach ($d in @($DefinitionValues)) {
        if (-not $d) { continue }
        $name = '(unknown)'
        $class = '-'
        $category = '-'
        if ($d.PSObject.Properties['definition'] -and $d.definition) {
            $name = $d.definition.displayName
            $class = $d.definition.classType
            if ($d.definition.PSObject.Properties['categoryPath']) { $category = $d.definition.categoryPath }
        }
        $state = 'Disabled'
        if ($d.enabled) { $state = 'Enabled' }
        $values = @()
        foreach ($pv in @($d.presentationValues)) {
            # @($null) yields a one-element array containing $null, so guard explicitly.
            if (-not $pv) { continue }
            $v = $null
            foreach ($cand in @('value', 'values')) {
                if ($pv.PSObject.Properties[$cand]) { $v = $pv.$cand; break }
            }
            if ($null -ne $v) {
                if ($v -isnot [string] -and $v -isnot [int] -and $v -isnot [bool]) { $v = (ConvertTo-Json $v -Depth 5 -Compress) }
                $values += [string]$v
            }
        }
        $rows += , @($category, $name, $class, $state, ($values -join '; '))
    }
    $sorted = @($rows | Sort-Object { $_[0] }, { $_[1] })
    return (New-IdsTable -Headers @('Category', 'Setting', 'Scope', 'State', 'Value') -Rows $sorted -AsData:$AsData)
}

function Format-IdsIntentSettings {
    param($Settings, [switch]$AsData)
    $rows = @()
    foreach ($s in $Settings) {
        if (-not $s) { continue }
        $name = Get-IdsPrettyId ([string]$s.definitionId)
        $val = '-'
        foreach ($candidate in @('value', 'valueJson')) {
            if ($s.PSObject.Properties[$candidate] -and $null -ne $s.$candidate) { $val = $s.$candidate; break }
        }
        if ($val -is [string] -and $val -eq 'null') { $val = '-' }
        $rows += , @($name, $val)
    }
    return (New-IdsTable -Headers @('Setting', 'Value') -Rows @($rows | Sort-Object { $_[0] }) -EmptyText '_No settings configured._' -AsData:$AsData)
}

function Format-IdsComplianceActions {
    param($ScheduledActions)
    $rows = @()
    foreach ($sa in @($ScheduledActions)) {
        if (-not $sa) { continue }
        foreach ($c in @($sa.scheduledActionConfigurations)) {
            if (-not $c) { continue }
            $recipients = '-'
            if ($c.PSObject.Properties['notificationMessageCCList'] -and $c.notificationMessageCCList) {
                $recipients = (@($c.notificationMessageCCList) -join ', ')
            }
            $rows += , @((Format-IdsOdataType $c.actionType), $c.gracePeriodHours, $recipients)
        }
    }
    return (New-IdsTable -Headers @('Action', 'Grace period (hours)', 'Additional recipients') -Rows $rows -EmptyText '_No scheduled actions._')
}

# --- Applications -----------------------------------------------------------------------

function Format-IdsAppType {
    param([string]$OdataType)
    $short = ($OdataType -replace '#microsoft\.graph\.', '')
    switch -Regex ($short) {
        '^win32CatalogApp$'                 { 'Win32 — Enterprise App Catalog'; break }
        '^win32LobApp$'                     { 'Win32 app'; break }
        '^winGetApp$'                       { 'Microsoft Store app (WinGet)'; break }
        '^windowsStoreApp$'                 { 'Microsoft Store app (legacy)'; break }
        '^windowsUniversalAppX'             { 'Windows Universal (AppX)'; break }
        '^windowsMicrosoftEdgeApp$'         { 'Microsoft Edge'; break }
        '^windowsWebApp$'                   { 'Web link (Windows)'; break }
        '^officeSuiteApp$'                  { 'Microsoft 365 Apps'; break }
        '^windowsAppX$'                     { 'Windows AppX'; break }
        '^macOS(Lob|Dmg|Pkg)App$'           { 'macOS app'; break }
        '^macOSMicrosoftDefenderApp$'       { 'Microsoft Defender for macOS'; break }
        '^macOSOfficeSuiteApp$'             { 'Microsoft 365 Apps for macOS'; break }
        '^iosStoreApp$'                     { 'iOS store app'; break }
        '^iosVppApp$'                       { 'iOS VPP app'; break }
        '^iosLobApp$'                       { 'iOS line-of-business app'; break }
        '^androidStoreApp$'                 { 'Android store app'; break }
        '^androidManagedStoreApp$'          { 'Managed Google Play app'; break }
        '^androidLobApp$'                   { 'Android line-of-business app'; break }
        '^webApp$'                          { 'Web link'; break }
        default                             { (Format-IdsOdataType $OdataType) }
    }
}

function Get-IdsAppPlatform {
    param([string]$OdataType)
    $short = ($OdataType -replace '#microsoft\.graph\.', '')
    if ($short -match '^win32|^winGet|^windows|^officeSuite') { return 'windows' }
    if ($short -match '^macOS')  { return 'macos' }
    if ($short -match '^ios')    { return 'ios' }
    if ($short -match '^android') { return 'android' }
    if ($short -match '^webApp') { return 'web' }
    return 'other'
}

function Format-IdsDetectionRules {
    param($Rules)
    $rows = @()
    foreach ($r in @($Rules)) {
        if (-not $r) { continue }
        $type = Format-IdsOdataType $r.'@odata.type'
        $detail = @()
        foreach ($p in ($r.PSObject.Properties | Sort-Object Name)) {
            if ($p.Name -like '*@odata*') { continue }
            if ($null -eq $p.Value -or ($p.Value -is [string] -and $p.Value -eq '')) { continue }
            $detail += ('{0}={1}' -f $p.Name, $p.Value)
        }
        $rows += , @($type, ($detail -join '; '))
    }
    return (New-IdsTable -Headers @('Rule type', 'Detail') -Rows $rows -EmptyText '_None._')
}

function Format-IdsAppInstallSettings {
    param($App)
    $props = [ordered]@{}
    $map = [ordered]@{
        publisher                = 'Publisher'
        developer                = 'Developer'
        owner                    = 'Owner'
        version                  = 'Version'
        displayVersion           = 'Display version'
        fileName                 = 'File name'
        setupFilePath            = 'Setup file'
        installCommandLine       = 'Install command'
        uninstallCommandLine     = 'Uninstall command'
        packageIdentifier        = 'Package identifier'
        appStoreUrl              = 'Store URL'
        bundleId                 = 'Bundle id'
        applicableArchitectures  = 'Architectures'
        allowAvailableUninstall  = 'User can uninstall'
        isFeatured               = 'Featured'
        privacyInformationUrl    = 'Privacy URL'
        informationUrl           = 'Information URL'
        notes                    = 'Notes'
    }
    foreach ($k in $map.Keys) {
        if ($App.PSObject.Properties[$k] -and $null -ne $App.$k -and "$($App.$k)" -ne '') { $props[$map[$k]] = $App.$k }
    }
    if ($App.PSObject.Properties['size'] -and $App.size) { $props['Size'] = Format-IdsBytes $App.size }
    if ($App.PSObject.Properties['minimumSupportedOperatingSystem'] -and $App.minimumSupportedOperatingSystem) {
        $oses = @()
        foreach ($p in $App.minimumSupportedOperatingSystem.PSObject.Properties) {
            if ($p.Value -eq $true) { $oses += ($p.Name -replace '^v', '' -replace '_', '.') }
        }
        if ($oses.Count -gt 0) { $props['Minimum OS'] = ($oses -join ', ') }
    }
    if ($App.PSObject.Properties['installExperience'] -and $App.installExperience) {
        $ie = $App.installExperience
        if ($ie.PSObject.Properties['runAsAccount']) { $props['Install context'] = $ie.runAsAccount }
        if ($ie.PSObject.Properties['deviceRestartBehavior']) { $props['Restart behaviour'] = $ie.deviceRestartBehavior }
        if ($ie.PSObject.Properties['maxRunTimeInMinutes']) { $props['Max run time (min)'] = $ie.maxRunTimeInMinutes }
    }
    return (New-IdsPropertyTable -Properties $props -EmptyText '_No install settings._')
}

# --- Page assembly ----------------------------------------------------------------------

function New-IdsFrontMatter {
    <#  Deliberately excludes any export-run timestamp: object pages must only change when
        the object itself changes. #>
    param([System.Collections.IDictionary]$Fields)
    if (-not $script:IdsOptions.FrontMatter) { return @() }
    $out = @('---')
    foreach ($k in $Fields.Keys) {
        $v = $Fields[$k]
        if ($null -eq $v -or "$v" -eq '') { continue }
        $s = [string]$v
        if ($s -match '[:#\[\]{}]' -or $s -match '^\s' -or $s -match '\s$') { $s = '"' + ($s -replace '"', '\"') + '"' }
        $out += ('{0}: {1}' -f $k, $s)
    }
    $out += '---'
    $out += ''
    return $out
}

function New-IdsDocument {
    <#  Assembles a complete Markdown page.
        Sections is an ordered dictionary of  Title -> body string (skipped when empty). #>
    param(
        [string]$Title,
        [string]$Description,
        [System.Collections.IDictionary]$FrontMatter,
        [System.Collections.IDictionary]$Overview,
        [System.Collections.IDictionary]$Sections,
        $Assignments,
        $Raw,
        [string]$RawLabel = 'Raw Graph object'
    )
    $lines = @()
    if ($FrontMatter) { $lines += New-IdsFrontMatter -Fields $FrontMatter }
    $lines += "# $Title"
    $lines += ''
    if ($Description) {
        foreach ($l in ($Description -split "`r?`n")) { $lines += "> $l" }
        $lines += ''
    }
    if ($Overview -and $Overview.Count -gt 0) {
        $lines += '## Overview'
        $lines += ''
        $lines += (New-IdsPropertyTable -Properties $Overview)
        $lines += ''
    }
    if ($Sections) {
        foreach ($k in $Sections.Keys) {
            $body = $Sections[$k]
            if ($null -eq $body -or "$body" -eq '') { continue }
            $lines += "## $k"
            $lines += ''
            $lines += $body
            $lines += ''
        }
    }
    if ($null -ne $Assignments) {
        $lines += '## Assignments'
        $lines += ''
        $lines += (Format-IdsAssignments -Assignments $Assignments)
        $lines += ''
    }
    if ($Raw -and $script:IdsOptions.IncludeRaw) {
        $lines += '## Source'
        $lines += ''
        $lines += "<details><summary>$RawLabel</summary>"
        $lines += ''
        $lines += '```json'
        $lines += (ConvertTo-IdsJson -InputObject $Raw)
        $lines += '```'
        $lines += ''
        $lines += '</details>'
        $lines += ''
    }
    return (($lines -join "`n").TrimEnd() + "`n")
}
