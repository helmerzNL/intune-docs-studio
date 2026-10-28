function New-IdsTestPackBytes {
    param([string]$Platform = 'windows11')
    $pack = @{
        schemaVersion = 1; id = 'synthetic-pack'; version = '1.0.0'
        framework = 'Synthetic'; frameworkVersion = '1'
        classification = 'recommendations'; platform = $Platform
        profile = 'test'; sourceRevision = 'synthetic-v1'
        sources = @(@{ id = 'source'; url = 'https://example.invalid/rules'
            revision = 'synthetic-v1'; retrievedOn = '2026-10-28' })
        coverage = @{ inventory = 'partial'; totalSourceControls = $null }
        controls = @(@{
            id = 'SYN-1'; title = 'Synthetic required setting'
            sourceIds = @('source'); reference = 'SYN-1'; manualReason = $null
            applicability = @{ osMin = $null; osMax = $null; enrollmentModes = @() }
            mappings = @(@{
                family = 'settingsCatalog'; policyTypes = @('configurationPolicy')
                settingId = 'synthetic.required'; property = $null
                instancePath = $null; valueType = 'boolean'
                operator = 'eq'; expected = $true; caseSensitive = $true
            })
        })
    }

    return ,([Text.Encoding]::UTF8.GetBytes(($pack | ConvertTo-Json -Depth 20)))
}

function New-IdsTestAssessmentPolicy {
    param([string]$Family = 'settingsCatalog',
        [string]$PolicyType = 'deviceManagementConfigurationPolicy',
        [object[]]$Settings = @(), $Template = $null)
    [pscustomobject]@{
        key = "${Family}:synthetic"; id = 'synthetic'; name = 'Synthetic Windows 11 fully managed'
        family = $Family; policyType = $PolicyType; platform = $null; template = $Template
        osMin = $null; osMax = $null; enrollmentMode = $null
        assignments = @(); settingsComplete = $true; assignmentsComplete = $true
        rawSettings = $Settings
    }
}

function New-IdsTestSettingInstance {
    param([string]$Kind = 'simple', [string]$Id = 'synthetic.setting', $Value = 0)
    $typeKind = $Kind.Substring(0, 1).ToUpperInvariant() + $Kind.Substring(1)
    $instance = @{ '@odata.type' = "#microsoft.graph.deviceManagementConfiguration${typeKind}SettingInstance"; settingDefinitionId = $Id }
    $instance["${Kind}SettingValue"] = $Value
    return $instance
}

function New-IdsTestAssessmentCollection {
    param([object[]]$Policies = @())
    [pscustomobject]@{ policies = $Policies; sources = @(); issues = @() }
}

function Assert-IdsTestMarkdownObservations {
    param([string]$Section, $Control)
    $row = [regex]::Match($Section, '(?m)^\| observed \| (.*) \|$')
    $row.Success | Should -BeTrue
    $records = ConvertFrom-Json -InputObject ([Net.WebUtility]::HtmlDecode($row.Groups[1].Value)) -NoEnumerate
    ConvertTo-Json -InputObject $records -Depth 20 -Compress |
        Should -Be (ConvertTo-Json -InputObject $Control.observed -Depth 20 -Compress)
}
