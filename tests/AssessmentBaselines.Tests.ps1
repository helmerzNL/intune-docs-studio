BeforeAll {
    . "$PSScriptRoot\TestHelpers\Assessment.ps1"
    . "$PSScriptRoot\..\lib\BaselinePacks.ps1"
    . "$PSScriptRoot\..\lib\AssessmentCollection.ps1"
    . "$PSScriptRoot\..\lib\AssessmentSettings.ps1"
    . "$PSScriptRoot\..\lib\AssessmentRules.ps1"
    $repo = Split-Path $PSScriptRoot -Parent

    function Invoke-BundledControl($File, $ControlId, $PolicyType, $Family, $Raw, $Platform, $Mode, $ContextOverride) {
        $pack = Read-IdsBaselinePack -Bytes ([IO.File]::ReadAllBytes((Join-Path $repo "baselines\$File")))
        $policy = New-IdsTestAssessmentPolicy -Family $Family -PolicyType $PolicyType -Settings @($Raw)
        if ($Platform -ceq 'windows11') { $policy.osMin = '10.0.22000' }
        $collection = New-IdsTestAssessmentCollection @($policy)
        $families = @(@($Family) + @($pack.controls.mappings.family) | Sort-Object -Unique)
        $collection.sources = @($families | ForEach-Object {
            [pscustomobject]@{ family = $_; platform = $Platform; complete = $true; errors = @() }
        })
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        $context = @{
            platforms = @($Platform)
            osVersions = @{ windows11 = '10.0.22000'; macos = '14.0' }
            enrollmentModes = @{ androidEnterprise = 'workProfile'; iosIpados = 'personallyOwned' }
        }
        if ($Mode) { $context.enrollmentModes[$Platform] = $Mode }
        if ($ContextOverride) { $context = $ContextOverride }
        $result = Compare-IdsAssessment -Packs @($pack) -Snapshot $snapshot -Context $context
        return @($result.controls | Where-Object controlId -CEQ $ControlId)[0]
    }
}

Describe 'Reviewed bundled Microsoft catalog' {
    It 'ships nonempty verified Microsoft coverage for every selected platform' {
        $catalog = Get-IdsBaselinePacks -BundledRoot (Join-Path $repo 'baselines') `
            -ImportedRoot (Join-Path $TestDrive 'imports')
        $catalog.errors.Count | Should -Be 0
        $catalog.packs.Count | Should -Be 4
        @($catalog.packs.controls).Count | Should -Be 5
        foreach ($platform in 'windows11', 'macos', 'iosIpados', 'androidEnterprise') {
            $packs = @($catalog.packs | Where-Object platform -CEQ $platform)
            $packs.Count | Should -BeGreaterThan 0
            foreach ($pack in $packs) {
                $pack.framework | Should -BeExactly 'Microsoft'
                $pack.version | Should -BeExactly '1.0.0'
                $pack.coverage.inventory | Should -BeExactly 'partial'
                $pack.coverage.totalSourceControls | Should -BeNullOrEmpty
                @($pack.controls | Where-Object { -not $_.manualReason }).Count | Should -BeGreaterThan 0
                foreach ($source in $pack.sources) {
                    ([uri]$source.url).Host | Should -BeExactly 'learn.microsoft.com'
                    $source.revision | Should -Not -BeNullOrEmpty
                }
                if ($platform -ceq 'windows11') {
                    $pack.classification | Should -BeExactly 'baseline'
                    $pack.frameworkVersion | Should -BeExactly 'Windows 26H2'
                } else {
                    $pack.classification | Should -BeExactly 'recommendations'
                }
            }
        }
    }

    It 'assesses the real <ControlId> mapping without coercing booleans' -ForEach @(
        @{ File = 'microsoft-windows-11.json'; ControlId = 'IDS-WIN-SHELL-SMARTSCREEN'; Platform = 'windows11'
           Family = 'deviceConfiguration'; PolicyType = 'windows10EndpointProtectionConfiguration'; Property = 'smartScreenEnableInShell' }
        @{ File = 'microsoft-windows-11.json'; ControlId = 'IDS-WIN-SHELL-NO-BYPASS'; Platform = 'windows11'
           Family = 'deviceConfiguration'; PolicyType = 'windows10EndpointProtectionConfiguration'; Property = 'smartScreenBlockOverrideForFiles' }
        @{ File = 'microsoft-macos.json'; ControlId = 'IDS-MAC-FILEVAULT'; Platform = 'macos'
           Family = 'deviceConfiguration'; PolicyType = 'macOSEndpointProtectionConfiguration'; Property = 'fileVaultEnabled' }
        @{ File = 'microsoft-ios-ipados.json'; ControlId = 'IDS-IOS-PASSCODE'; Platform = 'iosIpados'
           Family = 'deviceConfiguration'; PolicyType = 'iosGeneralDeviceConfiguration'; Property = 'passcodeRequired' }
        @{ File = 'microsoft-android-enterprise.json'; ControlId = 'IDS-ANDROID-ENCRYPTION'; Platform = 'androidEnterprise'
           Family = 'compliance'; PolicyType = 'androidWorkProfileCompliancePolicy'; Property = 'storageRequireEncryption' }
    ) {
        $args = @{
            File = $File; ControlId = $ControlId; Platform = $Platform
            Family = $Family; PolicyType = $PolicyType
        }
        $positive = Invoke-BundledControl @args -Raw @{ $Property = $true }
        $positive.status | Should -BeExactly 'aligned'
        $positive.observed.Count | Should -Be 1
        $positive.observed[0].value | Should -BeTrue
        $positive.policyResults.Count | Should -Be 1

        $negative = Invoke-BundledControl @args -Raw @{ $Property = $false }
        $negative.status | Should -BeExactly 'misaligned'
        $negative.observed[0].value | Should -BeFalse
        (Invoke-BundledControl @args -Raw @{}).status | Should -BeExactly 'missing'
        (Invoke-BundledControl @args -Raw @{ $Property = 'true' }).status | Should -BeExactly 'notAssessed'
    }

    It 'does not substitute an encryption compliance check for FileVault configuration' {
        $result = Invoke-BundledControl -File 'microsoft-macos.json' -ControlId 'IDS-MAC-FILEVAULT' `
            -Platform macos -Family compliance -PolicyType macOSCompliancePolicy `
            -Raw @{ storageRequireEncryption = $true }
        $result.status | Should -BeExactly 'missing'
        $result.observed.Count | Should -Be 0
    }

    It 'does not substitute iOS compliance for the recommended device restriction' {
        $result = Invoke-BundledControl -File 'microsoft-ios-ipados.json' -ControlId 'IDS-IOS-PASSCODE' `
            -Platform iosIpados -Family compliance -PolicyType iosCompliancePolicy `
            -Raw @{ passcodeRequired = $true }
        $result.status | Should -BeExactly 'missing'
        $result.observed.Count | Should -Be 0
    }

    It 'does not extend personal guidance to <Platform> corporate enrollment' -ForEach @(
        @{ File = 'microsoft-ios-ipados.json'; ControlId = 'IDS-IOS-PASSCODE'; Platform = 'iosIpados'
           Family = 'deviceConfiguration'; PolicyType = 'iosGeneralDeviceConfiguration'
           Property = 'passcodeRequired'; Mode = 'automatedDeviceEnrollment' }
        @{ File = 'microsoft-android-enterprise.json'; ControlId = 'IDS-ANDROID-ENCRYPTION'; Platform = 'androidEnterprise'
           Family = 'compliance'; PolicyType = 'androidWorkProfileCompliancePolicy'
           Property = 'storageRequireEncryption'; Mode = 'fullyManaged' }
    ) {
        $result = Invoke-BundledControl -File $File -ControlId $ControlId -Platform $Platform `
            -Family $Family -PolicyType $PolicyType -Raw @{ $Property = $true } -Mode $Mode
        $result.status | Should -BeExactly 'notApplicable'
    }

    It 'does not assume unknown personal enrollment applicability for <Platform>' -ForEach @(
        @{ File = 'microsoft-ios-ipados.json'; ControlId = 'IDS-IOS-PASSCODE'; Platform = 'iosIpados'
           Family = 'deviceConfiguration'; PolicyType = 'iosGeneralDeviceConfiguration'; Property = 'passcodeRequired' }
        @{ File = 'microsoft-android-enterprise.json'; ControlId = 'IDS-ANDROID-ENCRYPTION'; Platform = 'androidEnterprise'
           Family = 'compliance'; PolicyType = 'androidWorkProfileCompliancePolicy'; Property = 'storageRequireEncryption' }
    ) {
        $result = Invoke-BundledControl -File $File -ControlId $ControlId -Platform $Platform `
            -Family $Family -PolicyType $PolicyType -Raw @{ $Property = $true } `
            -ContextOverride @{ platforms = @($Platform); osVersions = @{}; enrollmentModes = @{} }
        $result.status | Should -BeExactly 'notAssessed'
    }

    It 'requires macOS version evidence and excludes versions before FileVault management support' {
        $args = @{
            File = 'microsoft-macos.json'; ControlId = 'IDS-MAC-FILEVAULT'; Platform = 'macos'
            Family = 'deviceConfiguration'; PolicyType = 'macOSEndpointProtectionConfiguration'
            Raw = @{ fileVaultEnabled = $true }
        }
        $context = @{ platforms = @('macos'); osVersions = @{}; enrollmentModes = @{} }
        (Invoke-BundledControl @args -ContextOverride $context).status | Should -BeExactly 'notAssessed'
        $context.osVersions.macos = '10.12'
        (Invoke-BundledControl @args -ContextOverride $context).status | Should -BeExactly 'notApplicable'
    }
}
