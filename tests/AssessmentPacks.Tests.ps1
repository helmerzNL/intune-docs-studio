BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers\Assessment.ps1')
    $scratch = Join-Path $repo ('.assessment-pack-tests-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($scratch)
    $installation = Join-Path $scratch 'synthetic-installation'
    $module = Join-Path $repo 'lib\BaselinePacks.ps1'
    if (Test-Path -LiteralPath $module) {
        $library = Join-Path $installation 'lib'
        [void][IO.Directory]::CreateDirectory($library)
        Copy-Item -LiteralPath $module -Destination $library
        . (Join-Path $library 'BaselinePacks.ps1')
    }
    function ConvertTo-TestBytes($Pack) {
        return ,([Text.Encoding]::UTF8.GetBytes(($Pack | ConvertTo-Json -Depth 60 -Compress)))
    }
    function New-TestPack {
        return ([Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes)) | ConvertFrom-Json)
    }
}

AfterAll {
    if ($scratch -and (Test-Path -LiteralPath $scratch)) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

Describe 'Assessment pack parsing and identity' {
    It 'validates a synthetic pack and hashes the original bytes' {
        $bytes = New-IdsTestPackBytes
        $pack = Read-IdsBaselinePack -Bytes $bytes
        $pack.controls.Count | Should -Be 1
        $pack.sha256 | Should -Match '^[0-9a-f]{64}$'
        $stream = [IO.MemoryStream]::new($bytes)
        try { $pack.sha256 | Should -Be ((Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()) }
        finally { $stream.Dispose() }
        $copy = New-TestPack
        $copy.controls[0].mappings[0].expected = $false
        $changed = ConvertTo-TestBytes $copy
        (Read-IdsBaselinePack -Bytes $changed).controls[0].mappings[0].expected | Should -BeFalse
        (Read-IdsBaselinePack -Bytes $changed).sha256 | Should -Not -Be $pack.sha256
    }

    It 'accepts platform <platform> without reshaping singleton and empty arrays' -ForEach @(
        @{ platform = 'windows11' }, @{ platform = 'macos' },
        @{ platform = 'iosIpados' }, @{ platform = 'androidEnterprise' }
    ) {
        $pack = Read-IdsBaselinePack -Bytes (New-IdsTestPackBytes -Platform $platform)
        $pack.platform | Should -BeExactly $platform
        ($pack.controls -is [array]) | Should -BeTrue
        ($pack.controls[0].mappings -is [array]) | Should -BeTrue
        ($pack.controls[0].applicability.enrollmentModes -is [array]) | Should -BeTrue
        $pack.controls[0].manualReason | Should -BeNullOrEmpty
    }

    It 'rejects malformed or ambiguous input: <name>' -ForEach @(
        @{ name = 'duplicate top-level member'; json = '{"id":"one","id":"two"}'; error = '*duplicate member*' }
        @{ name = 'duplicate nested member'; json = '{"nested":[{"a":1,"a":2}]}'; error = '*duplicate member*' }
        @{ name = 'case-colliding member'; json = '{"id":"one","ID":"two"}'; error = '*duplicate member*' }
        @{ name = 'trailing comma'; json = '{"id":"one",}'; error = '*JSON*' }
        @{ name = 'comment'; json = '{/*comment*/"id":"one"}'; error = '*JSON*' }
        @{ name = 'array root'; json = '[]'; error = '*object*' }
    ) {
        { Read-IdsBaselinePack -Bytes ([Text.Encoding]::UTF8.GetBytes($json)) } | Should -Throw $error
    }

    It 'rejects invalid UTF-8 rather than replacing bytes' {
        { Read-IdsBaselinePack -Bytes ([byte[]]@(123, 34, 120, 34, 58, 34, 255, 34, 125)) } |
            Should -Throw '*UTF-8*'
    }

    It 'rejects invalid contract mutation: <name>' -ForEach @(
        @{ name = 'schema version'; mutate = { param($p) $p.schemaVersion = 2 }; error = '*schemaVersion*' }
        @{ name = 'string schema version'; mutate = { param($p) $p.schemaVersion = '1' }; error = '*schemaVersion*' }
        @{ name = 'pack traversal id'; mutate = { param($p) $p.id = '..\escape' }; error = '*.id*' }
        @{ name = 'uppercase pack id'; mutate = { param($p) $p.id = 'Pack' }; error = '*.id*' }
        @{ name = 'pack id final newline'; mutate = { param($p) $p.id = "pack`n" }; error = '*.id*' }
        @{ name = 'version delimiter'; mutate = { param($p) $p.version = '1.0.0#x' }; error = '*version*' }
        @{ name = 'version final newline'; mutate = { param($p) $p.version = "1.0.0`n" }; error = '*version*' }
        @{ name = 'version leading zero'; mutate = { param($p) $p.version = '01.0.0' }; error = '*version*' }
        @{ name = 'prerelease leading zero'; mutate = { param($p) $p.version = '1.0.0-01' }; error = '*version*' }
        @{ name = 'wrong platform'; mutate = { param($p) $p.platform = 'windows10' }; error = '*platform*' }
        @{ name = 'wrong platform case'; mutate = { param($p) $p.platform = 'Windows11' }; error = '*platform*' }
        @{ name = 'unknown classification'; mutate = { param($p) $p.classification = 'certification' }; error = '*classification*' }
        @{ name = 'unknown root field'; mutate = { param($p) $p | Add-Member noteProperty script 'evil' }; error = '*unknown field*' }
        @{ name = 'supplied hash'; mutate = { param($p) $p | Add-Member noteProperty sha256 ('a' * 64) }; error = '*unknown field*' }
        @{ name = 'missing field'; mutate = { param($p) $p.PSObject.Properties.Remove('profile') }; error = '*profile*' }
        @{ name = 'empty title'; mutate = { param($p) $p.controls[0].title = ' ' }; error = '*title*' }
        @{ name = 'duplicate control id'; mutate = { param($p) $p.controls += $p.controls[0] }; error = '*duplicate control*' }
        @{ name = 'empty controls'; mutate = { param($p) $p.controls = @() }; error = '*controls*' }
        @{ name = 'object controls'; mutate = { param($p) $p.controls = $p.controls[0] }; error = '*controls*' }
        @{ name = 'empty sources'; mutate = { param($p) $p.sources = @() }; error = '*sources*' }
        @{ name = 'duplicate source'; mutate = { param($p) $p.sources += $p.sources[0] }; error = '*duplicate source*' }
        @{ name = 'missing source reference'; mutate = { param($p) $p.controls[0].sourceIds = @('absent') }; error = '*sourceIds*' }
        @{ name = 'empty source references'; mutate = { param($p) $p.controls[0].sourceIds = @() }; error = '*sourceIds*' }
        @{ name = 'source script URL'; mutate = { param($p) $p.sources[0].url = 'javascript:alert(1)' }; error = '*url*' }
        @{ name = 'source relative URL'; mutate = { param($p) $p.sources[0].url = '/rules' }; error = '*url*' }
        @{ name = 'source date'; mutate = { param($p) $p.sources[0].retrievedOn = '2026-02-30' }; error = '*retrievedOn*' }
        @{ name = 'coverage count below inventory'; mutate = { param($p) $p.coverage.totalSourceControls = 0 }; error = '*totalSourceControls*' }
        @{ name = 'complete count missing'; mutate = { param($p) $p.coverage.inventory = 'complete' }; error = '*totalSourceControls*' }
        @{ name = 'complete count mismatch'; mutate = { param($p) $p.coverage.inventory = 'complete'; $p.coverage.totalSourceControls = 2 }; error = '*totalSourceControls*' }
        @{ name = 'fractional inventory'; mutate = { param($p) $p.coverage.totalSourceControls = 1.5 }; error = '*totalSourceControls*' }
        @{ name = 'unknown nested field'; mutate = { param($p) $p.controls[0].applicability | Add-Member noteProperty script 'evil' }; error = '*unknown field*' }
        @{ name = 'bad OS version'; mutate = { param($p) $p.controls[0].applicability.osMin = 'latest' }; error = '*osMin*' }
        @{ name = 'reversed OS bounds'; mutate = { param($p) $p.controls[0].applicability.osMin = '12.0'; $p.controls[0].applicability.osMax = '11.0' }; error = '*osMax*' }
        @{ name = 'non-array enrollment'; mutate = { param($p) $p.controls[0].applicability.enrollmentModes = 'dedicated' }; error = '*enrollmentModes*' }
        @{ name = 'empty enrollment item'; mutate = { param($p) $p.controls[0].applicability.enrollmentModes = @('') }; error = '*enrollmentModes*' }
        @{ name = 'no mapping or manual reason'; mutate = { param($p) $p.controls[0].mappings = @() }; error = '*manualReason*' }
        @{ name = 'empty manual reason'; mutate = { param($p) $p.controls[0].mappings = @(); $p.controls[0].manualReason = ' ' }; error = '*manualReason*' }
        @{ name = 'manual and mapped'; mutate = { param($p) $p.controls[0].manualReason = 'Manual' }; error = '*manualReason*' }
        @{ name = 'unknown family'; mutate = { param($p) $p.controls[0].mappings[0].family = 'script' }; error = '*family*' }
        @{ name = 'empty policy types'; mutate = { param($p) $p.controls[0].mappings[0].policyTypes = @() }; error = '*policyTypes*' }
        @{ name = 'two selectors'; mutate = { param($p) $p.controls[0].mappings[0].property = 'arbitrary' }; error = '*selector*' }
        @{ name = 'no selector'; mutate = { param($p) $p.controls[0].mappings[0].settingId = $null }; error = '*selector*' }
        @{ name = 'unsupported operator'; mutate = { param($p) $p.controls[0].mappings[0].operator = 'execute' }; error = '*operator*' }
        @{ name = 'string boolean'; mutate = { param($p) $p.controls[0].mappings[0].expected = 'true' }; error = '*expected*' }
        @{ name = 'null expected'; mutate = { param($p) $p.controls[0].mappings[0].expected = $null }; error = '*expected*' }
        @{ name = 'numeric boolean'; mutate = { param($p) $p.controls[0].mappings[0].expected = 1 }; error = '*expected*' }
        @{ name = 'boolean numeric bound'; mutate = { param($p) $p.controls[0].mappings[0].operator = 'gte' }; error = '*operator*' }
        @{ name = 'scalar set comparison'; mutate = { param($p) $p.controls[0].mappings[0].operator = 'setEquals' }; error = '*operator*' }
        @{ name = 'scalar membership'; mutate = { param($p) $p.controls[0].mappings[0].operator = 'in' }; error = '*expected*' }
        @{ name = 'nonboolean case sensitivity'; mutate = { param($p) $p.controls[0].mappings[0].caseSensitive = 'false' }; error = '*caseSensitive*' }
        @{ name = 'wrong instance path type'; mutate = { param($p) $p.controls[0].mappings[0].instancePath = @('a') }; error = '*instancePath*' }
    ) {
        $pack = New-TestPack
        & $mutate $pack
        { Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $pack) } | Should -Throw $error
    }

    It 'accepts manual controls and complete inventories with an exact count' {
        $p = New-TestPack
        $p.controls[0].mappings = @()
        $p.controls[0].manualReason = 'Requires an independent review.'
        $p.coverage.inventory = 'complete'
        $p.coverage.totalSourceControls = 1
        $p.version = '1.2.3-rc.1+review.2'
        $pack = Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p)
        $pack.controls[0].mappings.Count | Should -Be 0
        $pack.coverage.totalSourceControls | Should -Be 1
    }

    It 'keeps date-like strings as strings and accepts valid OS applicability' {
        $p = New-TestPack
        $p.controls[0].applicability.osMin = '11'
        $p.controls[0].applicability.osMax = '11.4.0'
        $p.controls[0].applicability.enrollmentModes = @('synthetic-mode')
        $m = $p.controls[0].mappings[0]
        $m.valueType = 'string'; $m.expected = '2026-10-28T00:00:00Z'
        $pack = Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p)
        ($pack.controls[0].mappings[0].expected -is [string]) | Should -BeTrue
        $pack.controls[0].applicability.osMin | Should -BeExactly '11'
    }

    It 'rejects alternative mappings that describe different atomic checks' {
        $p = New-TestPack
        $other = (New-TestPack).controls[0].mappings[0]
        $other.expected = $false
        $p.controls[0].mappings += $other
        { Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p) } | Should -Throw '*atomic check*'
    }

    It 'accepts alternative stable-identifier mappings for the same atomic check' {
        $p = New-TestPack
        $other = (New-TestPack).controls[0].mappings[0]
        $other.family = 'intent'; $other.policyTypes = @('deviceManagementIntent')
        $other.settingId = 'synthetic.other'
        $p.controls[0].mappings += $other
        (Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p)).controls[0].mappings.Count | Should -Be 2
    }

    It 'keeps unordered alternative set expectations equivalent' {
        $p = New-TestPack
        $first = $p.controls[0].mappings[0]
        $first.valueType = 'stringSet'; $first.operator = 'setEquals'; $first.expected = @('b', 'a', 'a')
        $other = (New-TestPack).controls[0].mappings[0]
        $other.valueType = 'stringSet'; $other.operator = 'setEquals'; $other.expected = @('a', 'b')
        $p.controls[0].mappings += $other
        (Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p)).controls[0].mappings.Count | Should -Be 2
    }

    It 'preserves finite numeric expectations without decimal rounding: <number>' -ForEach @(
        @{ number = '1.4e-28'; expected = [double]1.4e-28 }
        @{ number = '-1.4e-28'; expected = [double]-1.4e-28 }
        @{ number = '1e-100'; expected = [double]1e-100 }
        @{ number = '-1e-100'; expected = [double]-1e-100 }
        @{ number = '1e-28'; expected = [decimal]0.0000000000000000000000000001 }
        @{ number = '0.10000'; expected = [decimal]0.1 }
        @{ number = '79228162514264337593543950335'; expected = [decimal]::MaxValue }
    ) {
        $p = New-TestPack
        $m = $p.controls[0].mappings[0]
        $m.valueType = 'number'; $m.expected = 'numeric-placeholder'
        $json = [Text.Encoding]::UTF8.GetString((ConvertTo-TestBytes $p)).Replace('"numeric-placeholder"', $number)
        $pack = Read-IdsBaselinePack -Bytes ([Text.Encoding]::UTF8.GetBytes($json))
        $actual = $pack.controls[0].mappings[0].expected
        if ($expected -is [double]) {
            ([double]$actual -eq $expected) | Should -BeTrue
        } else {
            ($actual -is [decimal]) | Should -BeTrue
            $actual | Should -Be $expected
        }
    }

    It 'rejects nonrepresentable numeric input: <number>' -ForEach @(
        @{ number = '1e999' }, @{ number = '1e-999' }, @{ number = '-1e-999' }
    ) {
        $p = New-TestPack
        $m = $p.controls[0].mappings[0]
        $m.valueType = 'number'; $m.expected = 'numeric-placeholder'
        $json = [Text.Encoding]::UTF8.GetString((ConvertTo-TestBytes $p)).Replace('"numeric-placeholder"', $number)
        { Read-IdsBaselinePack -Bytes ([Text.Encoding]::UTF8.GetBytes($json)) } | Should -Throw '*number*'
    }

    It 'compares alternative expectations by typed value: <name>' -ForEach @(
        @{ name = 'signed scalar zero'; type = 'number'; operator = 'eq'; first = '0'; second = '-0.0'; same = $true }
        @{ name = 'numeric exponent'; type = 'number'; operator = 'eq'; first = '100'; second = '1.00e2'; same = $true }
        @{ name = 'unordered numeric membership'; type = 'number'; operator = 'in'; first = '[0,1.4e-28,100,0]'; second = '[1e2,1.4e-28,-0.0]'; same = $true }
        @{ name = 'unordered numeric set'; type = 'numberSet'; operator = 'setEquals'; first = '[0,2,2]'; second = '[2.0,-0.0]'; same = $true }
        @{ name = 'different numeric sets'; type = 'numberSet'; operator = 'containsAll'; first = '[0,2]'; second = '[0,3]'; same = $false }
        @{ name = 'distinct precise integers'; type = 'number'; operator = 'eq'; first = '9007199254740992'; second = '9007199254740993'; same = $false }
        @{ name = 'ordinal scalar strings'; type = 'string'; operator = 'eq'; first = '"A"'; second = '"a"'; same = $false }
        @{ name = 'numeric-looking strings'; type = 'stringSet'; operator = 'setEquals'; first = '["0","2"]'; second = '["-0.0","2"]'; same = $false }
        @{ name = 'case-insensitive string sets'; type = 'stringSet'; operator = 'setEquals'; first = '["A","b"]'; second = '["B","a","a"]'; same = $true; caseSensitive = $false }
    ) {
        $p = New-TestPack
        $other = (New-TestPack).controls[0].mappings[0]
        $p.controls[0].mappings += $other
        foreach ($m in $p.controls[0].mappings) {
            $m.valueType = $type; $m.operator = $operator
            if ($null -ne $caseSensitive) { $m.caseSensitive = $caseSensitive }
        }
        $p.controls[0].mappings[0].expected = 'first-placeholder'
        $other.expected = 'second-placeholder'
        $json = [Text.Encoding]::UTF8.GetString((ConvertTo-TestBytes $p)).
            Replace('"first-placeholder"', $first).Replace('"second-placeholder"', $second)
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        if ($same) {
            (Read-IdsBaselinePack -Bytes $bytes).controls[0].mappings.Count | Should -Be 2
        } else {
            { Read-IdsBaselinePack -Bytes $bytes } | Should -Throw '*atomic check*'
        }
    }

    It 'accepts typed <type> <operator> expected values' -ForEach @(
        @{ type = 'boolean'; operator = 'ne'; expected = $false }
        @{ type = 'number'; operator = 'gte'; expected = 0 }
        @{ type = 'number'; operator = 'lte'; expected = -1.5 }
        @{ type = 'number'; operator = 'eq'; expected = 1 }
        @{ type = 'string'; operator = 'eq'; expected = '' }
        @{ type = 'string'; operator = 'in'; expected = @('a', 'b') }
        @{ type = 'number'; operator = 'in'; expected = @(0, 1) }
        @{ type = 'boolean'; operator = 'in'; expected = @($true, $false) }
        @{ type = 'stringSet'; operator = 'setEquals'; expected = @() }
        @{ type = 'numberSet'; operator = 'containsAll'; expected = @(0, 2) }
        @{ type = 'numberSet'; operator = 'ne'; expected = @(1) }
    ) {
        $p = New-TestPack
        $m = $p.controls[0].mappings[0]
        $m.valueType = $type; $m.operator = $operator; $m.expected = $expected
        $pack = Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p)
        $pack.controls[0].mappings[0].valueType | Should -BeExactly $type
    }

    It 'rejects invalid typed combinations: <name>' -ForEach @(
        @{ name = 'string number'; type = 'number'; operator = 'eq'; expected = '0' }
        @{ name = 'mixed numeric set'; type = 'numberSet'; operator = 'setEquals'; expected = @(1, '2') }
        @{ name = 'mixed string set'; type = 'stringSet'; operator = 'containsAll'; expected = @('a', 1) }
        @{ name = 'empty membership'; type = 'boolean'; operator = 'in'; expected = @() }
        @{ name = 'set membership'; type = 'stringSet'; operator = 'in'; expected = @('a') }
        @{ name = 'unknown type'; type = 'script'; operator = 'eq'; expected = 'a' }
        @{ name = 'string bound'; type = 'string'; operator = 'lte'; expected = 'a' }
    ) {
        $p = New-TestPack
        $m = $p.controls[0].mappings[0]
        $m.valueType = $type; $m.operator = $operator; $m.expected = $expected
        { Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p) } | Should -Throw '*mapping*'
    }
}

Describe 'Assessment pack resource limits' {
    It 'rejects bytes over 10 MiB before parsing' {
        { Read-IdsBaselinePack -Bytes ([byte[]]::new(10MB + 1)) } | Should -Throw '*10 MiB*'
    }
    It 'accepts a valid pack padded to exactly 10 MiB' {
        $bytes = New-IdsTestPackBytes
        $padded = [Text.Encoding]::UTF8.GetBytes(([Text.Encoding]::UTF8.GetString($bytes) + (' ' * (10MB - $bytes.Length))))
        (Read-IdsBaselinePack -Bytes $padded).id | Should -BeExactly 'synthetic-pack'
    }
    It 'rejects nesting over 32 levels' {
        $json = ('[' * 33) + '0' + (']' * 33)
        { Read-IdsBaselinePack -Bytes ([Text.Encoding]::UTF8.GetBytes($json)) } | Should -Throw '*32*'
    }
    It 'rejects strings over 32768 characters' {
        $p = New-TestPack; $p.framework = 'x' * 32769
        { Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p) } | Should -Throw '*32768*'
    }
    It 'accepts a string at the 32768 character limit' {
        $p = New-TestPack; $p.framework = 'x' * 32768
        (Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p)).framework.Length | Should -Be 32768
    }
    It 'rejects more than 20000 controls' {
        $p = New-TestPack; $p.controls = @($p.controls[0]) * 20001
        { Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p) } | Should -Throw '*20000*'
    }
    It 'accepts exactly 20000 unique manual controls' {
        $p = New-TestPack
        $p.controls = @(
            foreach ($index in 1..20000) {
                @{
                    id = "SYN-$index"; title = 'Synthetic'; sourceIds = @('source'); reference = "SYN-$index"
                    applicability = @{ osMin = $null; osMax = $null; enrollmentModes = @() }
                    manualReason = 'Review independently'; mappings = @()
                }
            }
        )
        (Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p)).controls.Count | Should -Be 20000
    }
}

Describe 'Assessment property selector allowlist' {
    It 'validates the reviewed macOS property types through the shared catalog' {
        $catalog = Get-IdsAssessmentPropertyCatalog
        ($catalog -is [hashtable]) | Should -BeTrue
        $catalog['compliance:macOSCompliancePolicy'].storageRequireEncryption | Should -BeExactly 'boolean'
        $catalog['compliance:macOSCompliancePolicy'].systemIntegrityProtectionEnabled | Should -BeExactly 'boolean'
        $catalog['compliance:macOSCompliancePolicy'].passwordMinimumLength | Should -BeExactly 'number'
        $p = New-TestPack; $p.platform = 'macos'
        $m = $p.controls[0].mappings[0]
        $m.family = 'compliance'; $m.policyTypes = @('macOSCompliancePolicy')
        $m.settingId = $null; $m.property = 'storageRequireEncryption'
        (Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p)).controls[0].mappings[0].property |
            Should -BeExactly 'storageRequireEncryption'
    }
    It 'rejects property selector mutation: <name>' -ForEach @(
        @{ name = 'unknown property'; property = 'password'; policyTypes = @('macOSCompliancePolicy'); family = 'compliance'; type = 'boolean' }
        @{ name = 'expression'; property = 'storageRequireEncryption.ToString()'; policyTypes = @('macOSCompliancePolicy'); family = 'compliance'; type = 'boolean' }
        @{ name = 'wrong type'; property = 'passwordMinimumLength'; policyTypes = @('macOSCompliancePolicy'); family = 'compliance'; type = 'boolean' }
        @{ name = 'unknown policy type'; property = 'storageRequireEncryption'; policyTypes = @('unknown'); family = 'compliance'; type = 'boolean' }
        @{ name = 'one unsupported alternative'; property = 'storageRequireEncryption'; policyTypes = @('macOSCompliancePolicy', 'unknown'); family = 'compliance'; type = 'boolean' }
        @{ name = 'wrong family'; property = 'storageRequireEncryption'; policyTypes = @('macOSCompliancePolicy'); family = 'deviceConfiguration'; type = 'boolean' }
        @{ name = 'wrong case'; property = 'StorageRequireEncryption'; policyTypes = @('macOSCompliancePolicy'); family = 'compliance'; type = 'boolean' }
    ) {
        $p = New-TestPack; $m = $p.controls[0].mappings[0]
        $m.settingId = $null; $m.property = $property; $m.policyTypes = $policyTypes
        $m.family = $family; $m.valueType = $type
        { Read-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p) } | Should -Throw '*property*'
    }
}

Describe 'Assessment pack local catalog and imports' {
    BeforeEach {
        $bundled = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        $imported = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($bundled)
    }
    It 'returns stable empty arrays for absent roots' {
        $catalog = Get-IdsBaselinePacks -BundledRoot $bundled -ImportedRoot $imported
        ($catalog.packs -is [array]) | Should -BeTrue
        ($catalog.errors -is [array]) | Should -BeTrue
        $catalog.packs.Count | Should -Be 0
        $catalog.errors.Count | Should -Be 0
    }
    It 'stores exact bytes with a generated filename and is idempotent' {
        $bytes = New-IdsTestPackBytes
        $pack = Import-IdsBaselinePack -Bytes $bytes -ImportedRoot $imported
        $again = Import-IdsBaselinePack -Bytes $bytes -ImportedRoot $imported
        $again.sha256 | Should -BeExactly $pack.sha256
        $files = @(Get-ChildItem -LiteralPath $imported -File)
        $files.Count | Should -Be 1
        $files[0].Name | Should -Match '^[a-f0-9]{64}\.json$'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($files[0].FullName)) |
            Should -BeExactly ([Convert]::ToBase64String($bytes))
    }
    It 'preserves an existing valid pack after invalid or conflicting imports' {
        $first = Import-IdsBaselinePack -Bytes (New-IdsTestPackBytes) -ImportedRoot $imported
        $p = New-TestPack; $p.controls[0].mappings[0].expected = 'false'
        { Import-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p) -ImportedRoot $imported } | Should -Throw '*expected*'
        $p.controls[0].mappings[0].expected = $false
        { Import-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p) -ImportedRoot $imported } | Should -Throw '*different bytes*'
        $catalog = Get-IdsBaselinePacks -BundledRoot $bundled -ImportedRoot $imported
        $catalog.packs.Count | Should -Be 1
        $catalog.packs[0].sha256 | Should -BeExactly $first.sha256
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 1
    }
    It 'rejects traversal pack IDs without creating a storage root' {
        $p = New-TestPack; $p.id = '..\escaped'
        { Import-IdsBaselinePack -Bytes (ConvertTo-TestBytes $p) -ImportedRoot $imported } | Should -Throw '*.id*'
        (Test-Path -LiteralPath $imported) | Should -BeFalse
    }
    It 'exposes corrupt entries and distinguishes origins without changing hashes' {
        $bytes = New-IdsTestPackBytes
        [IO.File]::WriteAllBytes((Join-Path $bundled 'public.json'), $bytes)
        $pack = Import-IdsBaselinePack -Bytes $bytes -ImportedRoot $imported
        [IO.File]::WriteAllText((Join-Path $imported 'corrupt.json'), '{broken')
        $catalog = Get-IdsBaselinePacks -BundledRoot $bundled -ImportedRoot $imported
        $catalog.packs.Count | Should -Be 2
        @($catalog.packs | Where-Object origin -CEQ 'bundled').Count | Should -Be 1
        @($catalog.packs | Where-Object origin -CEQ 'imported').Count | Should -Be 1
        @($catalog.packs | Where-Object sha256 -CEQ $pack.sha256).Count | Should -Be 2
        $catalog.errors.Count | Should -Be 1
        $catalog.errors[0].origin | Should -BeExactly 'imported'
        $catalog.errors[0].path | Should -BeExactly (Join-Path $imported 'corrupt.json')
        $catalog.errors[0].reason | Should -Match 'JSON'
    }
    It 'surfaces catalog identity conflicts instead of selecting arbitrary bytes' {
        $bytes = New-IdsTestPackBytes
        [IO.File]::WriteAllBytes((Join-Path $bundled 'one.json'), $bytes)
        $p = New-TestPack; $p.controls[0].mappings[0].expected = $false
        [IO.File]::WriteAllBytes((Join-Path $bundled 'two.json'), (ConvertTo-TestBytes $p))
        $catalog = Get-IdsBaselinePacks -BundledRoot $bundled -ImportedRoot $imported
        $catalog.packs.Count | Should -Be 0
        $catalog.errors.Count | Should -Be 2
        $catalog.errors[0].reason | Should -Match 'different bytes'
    }
    It 'fails closed when the imported catalog is corrupt' {
        [void][IO.Directory]::CreateDirectory($imported)
        [IO.File]::WriteAllText((Join-Path $imported 'corrupt.json'), '{}')
        { Import-IdsBaselinePack -Bytes (New-IdsTestPackBytes) -ImportedRoot $imported } | Should -Throw '*catalog*'
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 1
    }
    It 'surfaces a root that is a file and rejects relative import paths' {
        $file = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($file, 'not a directory')
        $catalog = Get-IdsBaselinePacks -BundledRoot $file -ImportedRoot $imported
        $catalog.errors.Count | Should -Be 1
        { Import-IdsBaselinePack -Bytes (New-IdsTestPackBytes) -ImportedRoot '.\relative' } | Should -Throw '*absolute*'
    }
    It 'rejects imports within or overlapping the installation before writing files' {
        $inside = Join-Path $installation 'customer-packs'
        { Import-IdsBaselinePack -Bytes (New-IdsTestPackBytes) -ImportedRoot $inside } | Should -Throw '*installation*'
        (Test-Path -LiteralPath $inside) | Should -BeFalse
        { Import-IdsBaselinePack -Bytes (New-IdsTestPackBytes) -ImportedRoot $scratch } | Should -Throw '*installation*'
    }
    It 'rejects a junction storage root that points into the installation' {
        $link = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Junction -Path $link -Target $installation)
        try {
            { Import-IdsBaselinePack -Bytes (New-IdsTestPackBytes) -ImportedRoot $link } | Should -Throw '*reparse*'
            @(Get-ChildItem -LiteralPath $installation -File -Filter '*.json').Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $link -Force }
    }
    It 'reports linked catalog entries instead of following them' {
        # A directory junction also exercises the catalog-root boundary without symlink privileges.
        $link = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Junction -Path $link -Target $bundled)
        try {
            $catalog = Get-IdsBaselinePacks -BundledRoot $link -ImportedRoot $imported
            $catalog.packs.Count | Should -Be 0
            $catalog.errors.Count | Should -Be 1
            $catalog.errors[0].reason | Should -Match 'reparse'
        } finally { Remove-Item -LiteralPath $link -Force }
    }
    It 'cleans up failed staged publication and leaves existing files untouched' {
        $bytes = New-IdsTestPackBytes
        $pack = Read-IdsBaselinePack -Bytes $bytes
        [void][IO.Directory]::CreateDirectory($imported)
        $occupied = Join-Path $imported "$($pack.sha256).json"
        [void][IO.Directory]::CreateDirectory($occupied)
        { Import-IdsBaselinePack -Bytes $bytes -ImportedRoot $imported } | Should -Throw
        (Test-Path -LiteralPath $occupied -PathType Container) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 1
    }
}

Describe 'Assessment pack batch imports' {
    BeforeEach {
        $imported = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        $one = New-IdsTestPackBytes
        $second = New-TestPack; $second.id = 'synthetic-pack-two'
        $two = ConvertTo-TestBytes $second
    }
    It 'imports each unique pack once and reports added in input order' {
        $first = @(Import-IdsBaselinePackSet -Packs @($two, $one) -ImportedRoot $imported)
        $first.Count | Should -Be 2
        $first[0].pack.id | Should -BeExactly 'synthetic-pack-two'
        $first[1].pack.id | Should -BeExactly 'synthetic-pack'
        $first[0].added | Should -BeTrue
        $first[1].added | Should -BeTrue
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 2
        foreach ($case in @(@{ result = $first[0]; bytes = $two }, @{ result = $first[1]; bytes = $one })) {
            $path = Join-Path $imported "$($case.result.pack.sha256).json"
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($case.bytes))
        }
        $again = @(Import-IdsBaselinePackSet -Packs @($two, $one) -ImportedRoot $imported)
        $again.Count | Should -Be 2
        $again[0].added | Should -BeFalse
        $again[1].added | Should -BeFalse
        $again[0].pack.sha256 | Should -BeExactly $first[0].pack.sha256
        $again[1].pack.sha256 | Should -BeExactly $first[1].pack.sha256
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 2
    }
    It 'drops byte-identical duplicates within a batch' {
        $results = @(Import-IdsBaselinePackSet -Packs @($one, $two, $one, $two) -ImportedRoot $imported)
        $results.Count | Should -Be 2
        @($results | Where-Object added).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 2
    }
    It 'validates the whole batch before creating the storage root' {
        $changed = New-TestPack; $changed.controls[0].mappings[0].expected = $false
        { Import-IdsBaselinePackSet -Packs @($one, (ConvertTo-TestBytes $changed)) -ImportedRoot $imported } |
            Should -Throw '*synthetic-pack@1.0.0*'
        { Import-IdsBaselinePackSet -Packs @($one, [Text.Encoding]::UTF8.GetBytes('{}')) -ImportedRoot $imported } |
            Should -Throw '*required*'
        (Test-Path -LiteralPath $imported) | Should -BeFalse
    }
    It 'rejects a conflict with an existing import before writing any pack of the batch' {
        $existing = Import-IdsBaselinePack -Bytes $one -ImportedRoot $imported
        $changed = New-TestPack; $changed.controls[0].mappings[0].expected = $false
        { Import-IdsBaselinePackSet -Packs @($two, (ConvertTo-TestBytes $changed)) -ImportedRoot $imported } |
            Should -Throw 'Imported pack ID/version already exists with different bytes.'
        $files = @(Get-ChildItem -LiteralPath $imported -Force)
        $files.Count | Should -Be 1
        $files[0].Name | Should -BeExactly "$($existing.sha256).json"
    }
    It 'keeps a single import as one validated pack' {
        $pack = Import-IdsBaselinePack -Bytes $one -ImportedRoot $imported
        ($pack -is [array]) | Should -BeFalse
        $pack.PSObject.Properties.Name | Should -Not -Contain 'added'
        $pack.id | Should -BeExactly 'synthetic-pack'
        $pack.controls.Count | Should -Be 1
        $pack.sha256 | Should -BeExactly (Read-IdsBaselinePack -Bytes $one).sha256
        (Import-IdsBaselinePack -Bytes $one -ImportedRoot $imported).sha256 | Should -BeExactly $pack.sha256
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 1
    }
    It 'honours another writer''s lock and releases its own lock after success and failure' {
        [void][IO.Directory]::CreateDirectory($imported)
        $lockPath = Join-Path $imported '.import.lock'
        $held = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        try {
            { Import-IdsBaselinePackSet -Packs @($one, $two) -ImportedRoot $imported } | Should -Throw
        } finally { $held.Dispose() }
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 0
        @(Import-IdsBaselinePackSet -Packs @($one, $two) -ImportedRoot $imported).Count | Should -Be 2
        (Test-Path -LiteralPath $lockPath) | Should -BeFalse
        $changed = New-TestPack; $changed.controls[0].mappings[0].expected = $false
        { Import-IdsBaselinePackSet -Packs @(, (ConvertTo-TestBytes $changed)) -ImportedRoot $imported } |
            Should -Throw '*different bytes*'
        (Test-Path -LiteralPath $lockPath) | Should -BeFalse
        $probe = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        $probe.Dispose()
        @(Get-ChildItem -LiteralPath $imported -Force).Count | Should -Be 2
    }
}
