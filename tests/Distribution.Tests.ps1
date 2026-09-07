#Requires -Version 5.1
<#
    Part A / B / AB: package format, strict manifest validation, immutable
    published versions, and channel promotion without a rebuild.
#>
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    Import-Module (Join-Path $modules 'Errors.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $modules 'Distribution.psm1') -Force -DisableNameChecking -Global

    function New-SourceTree {
        param([string] $Name, [int] $FileCount = 2)
        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        for ($i = 1; $i -le $FileCount; $i++) {
            Set-Content -LiteralPath (Join-Path $root ("file{0}.psm1" -f $i)) -Value "function Get-Thing$i { $i }" -Encoding UTF8
        }
        return $root
    }

    function New-Dist { param([string] $Name)
        $d = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    function Get-ThrownCode {
        param([scriptblock] $Action)
        try { & $Action | Out-Null; return '<no-throw>' }
        catch {
            if ($_.Exception.PSObject.Properties.Name -contains 'ErrorCode') { return $_.Exception.ErrorCode }
            return $_.Exception.GetType().Name
        }
    }
}
AfterAll { Remove-Module Distribution -Force -ErrorAction SilentlyContinue }

Describe 'Version strings' {
    It 'accepts <V>' -ForEach @(@{V='1.0.0'}, @{V='0.0.1'}, @{V='10.20.30'}) {
        Test-DevSetupVersionString -Version $V | Should -BeTrue
    }
    It 'rejects <V>' -ForEach @(
        @{V='1.0'}, @{V='1.0.0.0'}, @{V='1.0.0-beta'}, @{V='v1.0.0'}, @{V=''}, @{V='abc'}
    ) {
        Test-DevSetupVersionString -Version $V | Should -BeFalse
    }
    It 'ConvertTo-DevSetupVersion fails closed on a pre-release' {
        Get-ThrownCode { ConvertTo-DevSetupVersion -Version '1.0.0-beta' } | Should -Be 'DISTRIBUTION_VERSION_INVALID'
    }
}

Describe 'Checksums' {
    It 'writes one sorted line per file and hashes the list itself' {
        $src = New-SourceTree -Name 'cs-src' -FileCount 3
        $out = Join-Path $TestDrive 'SHA256SUMS.txt'
        $r = New-DevSetupChecksumFile -ContentPath $src -OutputPath $out -Confirm:$false
        $r.FileCount | Should -Be 3
        $r.Sha256 | Should -Match '^[0-9a-f]{64}$'
        $lines = @(Get-Content -LiteralPath $out)
        $lines.Count | Should -Be 3
        $lines[0] | Should -Match '^[0-9a-f]{64}  file1\.psm1$'
    }

    It 'is byte-stable across reruns' {
        $src = New-SourceTree -Name 'cs-stable' -FileCount 3
        $a = New-DevSetupChecksumFile -ContentPath $src -OutputPath (Join-Path $TestDrive 'a.txt') -Confirm:$false
        $b = New-DevSetupChecksumFile -ContentPath $src -OutputPath (Join-Path $TestDrive 'b.txt') -Confirm:$false
        $a.Sha256 | Should -Be $b.Sha256
    }

    It 'detects a modified file' {
        $src = New-SourceTree -Name 'cs-mod'
        $out = Join-Path $TestDrive 'mod.txt'
        New-DevSetupChecksumFile -ContentPath $src -OutputPath $out -Confirm:$false | Out-Null
        Add-Content -LiteralPath (Join-Path $src 'file1.psm1') -Value '# changed'
        $v = Test-DevSetupChecksumFile -ContentPath $src -ChecksumPath $out
        $v.IsValid | Should -BeFalse
        $v.Mismatched | Should -Contain 'file1.psm1'
    }

    It 'detects a deleted file' {
        $src = New-SourceTree -Name 'cs-del'
        $out = Join-Path $TestDrive 'del.txt'
        New-DevSetupChecksumFile -ContentPath $src -OutputPath $out -Confirm:$false | Out-Null
        Remove-Item -LiteralPath (Join-Path $src 'file1.psm1') -Force
        (Test-DevSetupChecksumFile -ContentPath $src -ChecksumPath $out).Missing | Should -Contain 'file1.psm1'
    }

    It 'detects an injected file that is not listed' {
        $src = New-SourceTree -Name 'cs-add'
        $out = Join-Path $TestDrive 'add.txt'
        New-DevSetupChecksumFile -ContentPath $src -OutputPath $out -Confirm:$false | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'sneaky.ps1') -Value 'whoami' -Encoding UTF8
        (Test-DevSetupChecksumFile -ContentPath $src -ChecksumPath $out).Unexpected | Should -Contain 'sneaky.ps1'
    }

    It 'records nested paths with forward slashes' {
        $src = New-SourceTree -Name 'cs-nested'
        New-Item -ItemType Directory -Path (Join-Path $src 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'sub/inner.psm1') -Value 'x' -Encoding UTF8
        $out = Join-Path $TestDrive 'nested.txt'
        New-DevSetupChecksumFile -ContentPath $src -OutputPath $out -Confirm:$false | Out-Null
        (Get-Content -LiteralPath $out -Raw) | Should -Match 'sub/inner\.psm1'
    }
}

Describe 'Manifest validation is strict but forward compatible' {
    BeforeAll {
        $script:GoodChannel = [pscustomobject]@{
            schemaVersion = 1; product = 'DevSetup'; channel = 'stable'; version = '1.9.0'
            manifest = 'packages/1.9.0/manifest.json'; minimumSupportedVersion = '1.7.0'
            force = $false; publishedUtc = '2026-09-06T19:30:00Z'
        }
    }

    It 'accepts a well-formed channel manifest' {
        (Test-DevSetupChannelManifest -Manifest $script:GoodChannel).IsValid | Should -BeTrue
    }

    It 'tolerates unknown future fields' {
        $m = $script:GoodChannel.PSObject.Copy()
        $m | Add-Member -NotePropertyName 'somethingNew' -NotePropertyValue 'x'
        (Test-DevSetupChannelManifest -Manifest $m).IsValid | Should -BeTrue
    }

    It 'rejects a missing required field' {
        $m = [pscustomobject]@{ schemaVersion = 1; product = 'DevSetup'; channel = 'stable' }
        $r = Test-DevSetupChannelManifest -Manifest $m
        $r.IsValid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'version'
    }

    It 'rejects a wrong type for <Field>' -ForEach @(
        @{ Field = 'force';         Bad = 'yes' }
        @{ Field = 'schemaVersion'; Bad = '1' }
        @{ Field = 'version';       Bad = '1.9' }
    ) {
        $m = $script:GoodChannel.PSObject.Copy()
        $m.$Field = $Bad
        (Test-DevSetupChannelManifest -Manifest $m).IsValid | Should -BeFalse
    }

    It 'rejects an unsupported schemaVersion' {
        $m = $script:GoodChannel.PSObject.Copy(); $m.schemaVersion = 99
        (Test-DevSetupChannelManifest -Manifest $m).IsValid | Should -BeFalse
    }

    It 'rejects a foreign product' {
        $m = $script:GoodChannel.PSObject.Copy(); $m.product = 'SomethingElse'
        (Test-DevSetupChannelManifest -Manifest $m).IsValid | Should -BeFalse
    }

    It 'rejects minimumSupportedVersion above version' {
        $m = $script:GoodChannel.PSObject.Copy(); $m.minimumSupportedVersion = '2.0.0'
        (Test-DevSetupChannelManifest -Manifest $m).IsValid | Should -BeFalse
    }

    It 'accepts publishedUtc as a DateTime, because ConvertFrom-Json produces one' {
        $m = $script:GoodChannel.PSObject.Copy()
        $m.publishedUtc = [datetime]::UtcNow
        (Test-DevSetupChannelManifest -Manifest $m).IsValid | Should -BeTrue
    }

    It 'rejects a null manifest' {
        (Test-DevSetupChannelManifest -Manifest $null).IsValid | Should -BeFalse
    }
}

Describe 'Publishing and immutability' {
    It 'publishes a version with content, checksums and a manifest' {
        $dist = New-Dist -Name 'pub1'
        $src = New-SourceTree -Name 'pub1-src' -FileCount 2
        $p = New-DevSetupPackage -DistributionRoot $dist -Version '1.0.0' -SourcePaths @($src) -Confirm:$false
        $p.Created | Should -BeTrue
        $p.FileCount | Should -Be 2
        Test-Path -LiteralPath $p.ManifestPath | Should -BeTrue
        Test-Path -LiteralPath $p.ChecksumPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $p.ContentDir (Split-Path $src -Leaf)) | Should -BeTrue
    }

    It 'validates a freshly published version' {
        $dist = New-Dist -Name 'pub2'
        New-DevSetupPackage -DistributionRoot $dist -Version '1.0.0' -SourcePaths @((New-SourceTree -Name 'pub2-src')) -Confirm:$false | Out-Null
        (Test-DevSetupPublishedPackage -DistributionRoot $dist -Version '1.0.0').IsValid | Should -BeTrue
    }

    It 'refuses to republish an existing version' {
        $dist = New-Dist -Name 'pub3'
        $src = New-SourceTree -Name 'pub3-src'
        New-DevSetupPackage -DistributionRoot $dist -Version '1.0.0' -SourcePaths @($src) -Confirm:$false | Out-Null
        Get-ThrownCode { New-DevSetupPackage -DistributionRoot $dist -Version '1.0.0' -SourcePaths @($src) -Confirm:$false } |
            Should -Be 'DISTRIBUTION_VERSION_EXISTS'
    }

    It 'refuses to publish an empty package' {
        $dist = New-Dist -Name 'pub4'
        $empty = Join-Path $TestDrive 'empty-src'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        Get-ThrownCode { New-DevSetupPackage -DistributionRoot $dist -Version '1.0.0' -SourcePaths @($empty) -Confirm:$false } |
            Should -Be 'DISTRIBUTION_PACKAGE_EMPTY'
    }

    It 'rejects a missing source directory' {
        $dist = New-Dist -Name 'pub5'
        Get-ThrownCode { New-DevSetupPackage -DistributionRoot $dist -Version '1.0.0' -SourcePaths @((Join-Path $TestDrive 'nope')) -Confirm:$false } |
            Should -Be 'DISTRIBUTION_SOURCE_MISSING'
    }

    It 'changes nothing under -WhatIf' {
        $dist = New-Dist -Name 'pub6'
        $r = New-DevSetupPackage -DistributionRoot $dist -Version '1.0.0' -SourcePaths @((New-SourceTree -Name 'pub6-src')) -WhatIf
        $r.Created | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dist 'packages/1.0.0') | Should -BeFalse
    }

    It 'detects a tampered file in a published version' {
        $dist = New-Dist -Name 'pub7'
        $p = New-DevSetupPackage -DistributionRoot $dist -Version '1.0.0' -SourcePaths @((New-SourceTree -Name 'pub7-src')) -Confirm:$false
        $victim = Get-ChildItem -LiteralPath $p.ContentDir -Recurse -File | Select-Object -First 1
        Add-Content -LiteralPath $victim.FullName -Value '# tampered'
        $v = Test-DevSetupPublishedPackage -DistributionRoot $dist -Version '1.0.0'
        $v.IsValid | Should -BeFalse
        ($v.Errors -join ' ') | Should -Match 'Checksum mismatch'
    }

    It 'detects a swapped checksum list' {
        $dist = New-Dist -Name 'pub8'
        $p = New-DevSetupPackage -DistributionRoot $dist -Version '1.0.0' -SourcePaths @((New-SourceTree -Name 'pub8-src')) -Confirm:$false
        Set-Content -LiteralPath $p.ChecksumPath -Value 'deadbeef  file1.psm1' -Encoding UTF8 -NoNewline
        $v = Test-DevSetupPublishedPackage -DistributionRoot $dist -Version '1.0.0'
        $v.IsValid | Should -BeFalse
        ($v.Errors -join ' ') | Should -Match 'checksumsSha256'
    }

    It 'lists published versions newest first' {
        $dist = New-Dist -Name 'pub9'
        $src = New-SourceTree -Name 'pub9-src'
        foreach ($v in '1.0.0', '1.10.0', '1.2.0') {
            New-DevSetupPackage -DistributionRoot $dist -Version $v -SourcePaths @($src) -Confirm:$false | Out-Null
        }
        (Get-DevSetupPublishedVersion -DistributionRoot $dist) -join ',' | Should -Be '1.10.0,1.2.0,1.0.0'
    }
}

Describe 'Channels and promotion (Part AB)' {
    BeforeAll {
        $script:PromoDist = New-Dist -Name 'promo'
        $script:PromoSrc = New-SourceTree -Name 'promo-src'
        foreach ($v in '1.9.3', '1.10.0') {
            New-DevSetupPackage -DistributionRoot $script:PromoDist -Version $v -SourcePaths @($script:PromoSrc) -Confirm:$false | Out-Null
        }
    }

    It 'points a channel at a published version' {
        $r = Set-DevSetupChannel -DistributionRoot $script:PromoDist -Channel stable -Version '1.9.3' -MinimumSupportedVersion '1.9.0' -Confirm:$false
        $r.Changed | Should -BeTrue
        (Get-DevSetupChannel -DistributionRoot $script:PromoDist -Channel stable).version | Should -Be '1.9.3'
    }

    It 'promotes pilot ahead of stable without building anything new' {
        $before = @(Get-DevSetupPublishedVersion -DistributionRoot $script:PromoDist)
        Set-DevSetupChannel -DistributionRoot $script:PromoDist -Channel pilot -Version '1.10.0' -MinimumSupportedVersion '1.9.0' -Confirm:$false | Out-Null
        (Get-DevSetupChannel -DistributionRoot $script:PromoDist -Channel pilot).version | Should -Be '1.10.0'
        (Get-DevSetupChannel -DistributionRoot $script:PromoDist -Channel stable).version | Should -Be '1.9.3'
        (@(Get-DevSetupPublishedVersion -DistributionRoot $script:PromoDist) -join ',') | Should -Be ($before -join ',')
    }

    It 'promotes stable to the already-published pilot version' {
        Set-DevSetupChannel -DistributionRoot $script:PromoDist -Channel stable -Version '1.10.0' -Confirm:$false | Out-Null
        (Get-DevSetupChannel -DistributionRoot $script:PromoDist -Channel stable).version | Should -Be '1.10.0'
    }

    It 'keeps the existing minimumSupportedVersion when none is given' {
        (Get-DevSetupChannel -DistributionRoot $script:PromoDist -Channel stable).minimumSupportedVersion | Should -Be '1.9.0'
    }

    It 'refuses to point a channel at a version that was never published' {
        Get-ThrownCode { Set-DevSetupChannel -DistributionRoot $script:PromoDist -Channel pilot -Version '9.9.9' -Confirm:$false } |
            Should -Be 'DISTRIBUTION_PROMOTION_INVALID'
    }

    It 'refuses to point a channel at a corrupt version' {
        $dist = New-Dist -Name 'promo-bad'
        $p = New-DevSetupPackage -DistributionRoot $dist -Version '1.0.0' -SourcePaths @((New-SourceTree -Name 'promo-bad-src')) -Confirm:$false
        Add-Content -LiteralPath (Get-ChildItem -LiteralPath $p.ContentDir -Recurse -File | Select-Object -First 1).FullName -Value '# tampered'
        Get-ThrownCode { Set-DevSetupChannel -DistributionRoot $dist -Channel stable -Version '1.0.0' -Confirm:$false } |
            Should -Be 'DISTRIBUTION_PROMOTION_INVALID'
    }

    It 'refuses a minimumSupportedVersion above the channel version' {
        Get-ThrownCode { Set-DevSetupChannel -DistributionRoot $script:PromoDist -Channel stable -Version '1.9.3' -MinimumSupportedVersion '2.0.0' -Confirm:$false } |
            Should -Be 'DISTRIBUTION_CHANNEL_INVALID'
    }

    It 'writes force=true when asked' {
        Set-DevSetupChannel -DistributionRoot $script:PromoDist -Channel pilot -Version '1.10.0' -Force -Confirm:$false | Out-Null
        (Get-DevSetupChannel -DistributionRoot $script:PromoDist -Channel pilot).force | Should -BeTrue
    }

    It 'changes nothing under -WhatIf' {
        $before = (Get-DevSetupChannel -DistributionRoot $script:PromoDist -Channel stable).version
        Set-DevSetupChannel -DistributionRoot $script:PromoDist -Channel stable -Version '1.9.3' -WhatIf | Out-Null
        (Get-DevSetupChannel -DistributionRoot $script:PromoDist -Channel stable).version | Should -Be $before
    }

    It 'rejects a corrupt channel file' {
        $dist = New-Dist -Name 'badchannel'
        New-Item -ItemType Directory -Path (Join-Path $dist 'channels') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dist 'channels/stable.json') -Value '{ not json' -Encoding UTF8
        Get-ThrownCode { Get-DevSetupChannel -DistributionRoot $dist -Channel stable } | Should -Be 'DISTRIBUTION_JSON_INVALID'
    }
}
