#Requires -Version 5.1
<#
    Parts D / E / F / G / H: the client bootstrap.

    Get-DevSetupBootDecision is a pure function, so the whole decision matrix
    (no update, upgrade available, offline, minimumSupportedVersion, force,
    previously failed version) is tested directly. Staging, activation,
    rollback and locking are tested against a real filesystem.
#>
BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'PythonVenvAutomation/templates/DevSetup.Bootstrap.ps1')

    function New-Install {
        param([string] $Name)
        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return (Get-DevSetupBootPaths -InstallRoot $root)
    }

    # Builds a package directory by hand so tests do not depend on Distribution.psm1.
    function New-TestPackage {
        param(
            [string] $Root,
            [string] $Version,
            [switch] $BreakChecksum,
            [switch] $BreakManifestHash,
            [switch] $NoModule,
            [switch] $BrokenSyntax
        )
        $pkg = Join-Path $Root $Version
        $content = Join-Path $pkg 'content'
        $moduleDir = Join-Path $content 'PythonVenvAutomation'
        New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null

        if (-not $NoModule) {
            $psm1 = if ($BrokenSyntax) { "function Broken { if (" } else { "function Get-Thing { 'ok' }`nExport-ModuleMember -Function Get-Thing" }
            Set-Content -LiteralPath (Join-Path $moduleDir 'PythonVenvAutomation.psm1') -Value $psm1 -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $moduleDir 'PythonVenvAutomation.psd1') -Encoding UTF8 -Value @"
@{ RootModule = 'PythonVenvAutomation.psm1'; ModuleVersion = '$Version'; GUID = 'b3d4f2a1-6c8e-4a2b-9f1d-2e7c5a9b0c34'; FunctionsToExport = @('Get-Thing') }
"@
        } else {
            Set-Content -LiteralPath (Join-Path $moduleDir 'readme.txt') -Value 'no module here' -Encoding UTF8
        }

        # SHA256SUMS.txt
        $root = (Resolve-Path -LiteralPath $content).Path
        $lines = @()
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)) {
            $rel = ($f.FullName.Substring($root.Length).TrimStart([char]'\', [char]'/')) -replace '\\', '/'
            $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $lines += ('{0}  {1}' -f $h, $rel)
        }
        $lines = @($lines | Sort-Object { ($_ -split '  ', 2)[1] })
        $text = ($lines -join "`n") + "`n"
        if ($BreakChecksum) { $text = $text -replace '^[0-9a-f]{64}', ('0' * 64) }
        $checksumPath = Join-Path $pkg 'SHA256SUMS.txt'
        Set-Content -LiteralPath $checksumPath -Value $text -Encoding UTF8 -NoNewline

        $listHash = Get-DevSetupBootTextSha256 -Text $text
        if ($BreakManifestHash) { $listHash = '1' * 64 }

        $manifest = [ordered]@{
            schemaVersion = 1; product = 'DevSetup'; version = $Version
            contentPath = 'content'; checksums = 'SHA256SUMS.txt'
            checksumsSha256 = $listHash; fileCount = $lines.Count
            channel = 'stable'; minimumBootstrapVersion = '1.0.0'
            publishedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        Set-Content -LiteralPath (Join-Path $pkg 'manifest.json') -Value ($manifest | ConvertTo-Json -Depth 5) -Encoding UTF8
        return $pkg
    }
}

Describe 'Get-DevSetupBootDecision - online' {
    It 'does nothing when the installed version is current' {
        (Get-DevSetupBootDecision -InstalledVersion '1.9.0' -ChannelVersion '1.9.0' -MinimumSupportedVersion '1.7.0').Action |
            Should -Be 'none'
    }
    It 'does nothing when the installed version is newer than the channel' {
        (Get-DevSetupBootDecision -InstalledVersion '1.10.0' -ChannelVersion '1.9.0' -MinimumSupportedVersion '1.7.0').Action |
            Should -Be 'none'
    }
    It 'updates when a newer version is offered' {
        $d = Get-DevSetupBootDecision -InstalledVersion '1.8.0' -ChannelVersion '1.9.0' -MinimumSupportedVersion '1.7.0'
        $d.Action | Should -Be 'update'
        "$($d.Target)" | Should -Be '1.9.0'
    }
    It 'installs when nothing is present' {
        (Get-DevSetupBootDecision -InstalledVersion $null -ChannelVersion '1.9.0' -MinimumSupportedVersion '1.7.0').Action |
            Should -Be 'install'
    }
    It 'updates when the installed version is below minimumSupportedVersion' {
        $d = Get-DevSetupBootDecision -InstalledVersion '1.6.0' -ChannelVersion '1.9.0' -MinimumSupportedVersion '1.7.0'
        $d.Action | Should -Be 'update'
        $d.Reason | Should -Match 'below the supported minimum'
    }
    It 'fails when the channel names no usable version' {
        (Get-DevSetupBootDecision -InstalledVersion '1.9.0' -ChannelVersion $null -MinimumSupportedVersion '1.7.0').Action |
            Should -Be 'fail'
    }
    It 'does not retry a version that already failed to activate' {
        $d = Get-DevSetupBootDecision -InstalledVersion '1.8.0' -ChannelVersion '1.9.0' `
            -MinimumSupportedVersion '1.7.0' -FailedVersions @('1.9.0')
        $d.Action | Should -Be 'none'
        $d.Reason | Should -Match 'previously failed'
    }
    It 'still upgrades to a different version when an older one failed' {
        (Get-DevSetupBootDecision -InstalledVersion '1.8.0' -ChannelVersion '1.9.1' `
            -MinimumSupportedVersion '1.7.0' -FailedVersions @('1.9.0')).Action | Should -Be 'update'
    }
}

Describe 'Get-DevSetupBootDecision - offline (Part E)' {
    It 'continues with the installed version when it is still supported' {
        $d = Get-DevSetupBootDecision -InstalledVersion '1.8.0' -ChannelVersion $null `
            -MinimumSupportedVersion '1.7.0' -ChannelReachable $false
        $d.Action | Should -Be 'none'
        $d.Reason | Should -Match 'Could not check'
    }
    It 'fails when the installed version is below the last known minimum' {
        $d = Get-DevSetupBootDecision -InstalledVersion '1.6.0' -ChannelVersion $null `
            -MinimumSupportedVersion '1.7.0' -ChannelReachable $false
        $d.Action | Should -Be 'fail'
        $d.Reason | Should -Match 'no longer supported'
    }
    It 'fails when nothing is installed at all' {
        (Get-DevSetupBootDecision -InstalledVersion $null -ChannelVersion $null -ChannelReachable $false).Action |
            Should -Be 'fail'
    }
    It 'fails for a forced channel version, with no offline fallback' {
        $d = Get-DevSetupBootDecision -InstalledVersion '1.8.0' -ChannelVersion $null `
            -MinimumSupportedVersion '1.7.0' -ChannelReachable $false -Force $true
        $d.Action | Should -Be 'fail'
        $d.Reason | Should -Match 'mandatory'
    }
    It 'fails when offline continuation is disabled' {
        (Get-DevSetupBootDecision -InstalledVersion '1.8.0' -ChannelVersion $null `
            -MinimumSupportedVersion '1.7.0' -ChannelReachable $false -AllowOfflineContinue $false).Action |
            Should -Be 'fail'
    }
}

Describe 'Activation state is written atomically (Part F)' {
    It 'round-trips state' {
        $p = New-Install -Name 'state1'
        Set-DevSetupBootState -StateFile $p.StateFile -State @{
            version = '1.9.0'; previousVersion = '1.8.0'
            activatedUtc = '2026-09-06T10:00:00Z'; failedVersions = @('1.7.9')
        } -Confirm:$false
        $s = Get-DevSetupBootState -StateFile $p.StateFile
        $s.version | Should -Be '1.9.0'
        $s.previousVersion | Should -Be '1.8.0'
        $s.failedVersions | Should -Contain '1.7.9'
    }
    It 'returns empty state when the file does not exist' {
        (Get-DevSetupBootState -StateFile (Join-Path $TestDrive 'nope/current.json')).version | Should -BeNullOrEmpty
    }
    It 'treats a corrupt state file as empty instead of crashing' {
        $p = New-Install -Name 'state2'
        New-Item -ItemType Directory -Path $p.State -Force | Out-Null
        Set-Content -LiteralPath $p.StateFile -Value '{ not json' -Encoding UTF8
        (Get-DevSetupBootState -StateFile $p.StateFile).version | Should -BeNullOrEmpty
    }
    It 'accepts partial state under Set-StrictMode -Version Latest' {
        # A missing hashtable key throws under StrictMode Latest, which is what
        # Run-Tests.ps1 and the shim both run under.
        $p = New-Install -Name 'state-partial'
        Set-StrictMode -Version Latest
        { Set-DevSetupBootState -StateFile $p.StateFile -State @{ version = '1.0.0' } -Confirm:$false } |
            Should -Not -Throw
        (Get-DevSetupBootState -StateFile $p.StateFile).version | Should -Be '1.0.0'
    }

    It 'preserves keys it does not know about, such as lastKnownMinimum' {
        # The offline minimumSupportedVersion check depends on this surviving.
        $p = New-Install -Name 'state-extra'
        Set-DevSetupBootState -StateFile $p.StateFile -Confirm:$false -State @{
            version = '1.9.0'; failedVersions = @(); lastKnownMinimum = '1.7.0'
        }
        $s = Get-DevSetupBootState -StateFile $p.StateFile
        $s.lastKnownMinimum | Should -Be '1.7.0'
    }

    It 'leaves no temp file behind' {
        $p = New-Install -Name 'state3'
        Set-DevSetupBootState -StateFile $p.StateFile -State @{ version = '1.0.0'; failedVersions = @() } -Confirm:$false
        $leftovers = @(Get-ChildItem -LiteralPath $p.State -Filter '*.tmp' -Force | ForEach-Object Name)
        $leftovers.Count | Should -Be 0 -Because ("leftovers: [{0}] in {1}; all: [{2}]" -f ($leftovers -join ','), $p.State, ((Get-ChildItem -LiteralPath $p.State -Force | ForEach-Object Name) -join ','))
    }
}

Describe 'Update lock (Part H)' {
    It 'acquires and releases' {
        $p = New-Install -Name 'lock1'
        Enter-DevSetupBootLock -Path $p.LockFile -WaitSeconds 2 | Should -BeTrue
        Test-Path -LiteralPath $p.LockFile | Should -BeTrue
        Exit-DevSetupBootLock -Path $p.LockFile
        Test-Path -LiteralPath $p.LockFile | Should -BeFalse
    }

    It 'refuses while a live process holds the lock' {
        $p = New-Install -Name 'lock2'
        New-Item -ItemType Directory -Path $p.State -Force | Out-Null
        # Our own PID is definitely alive.
        Set-Content -LiteralPath $p.LockFile -Encoding UTF8 -Value (@{
            processId = $PID; host = 'test'; takenUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Compress)
        Enter-DevSetupBootLock -Path $p.LockFile -WaitSeconds 1 -StaleMinutes 60 | Should -BeFalse
    }

    It 'breaks a lock whose owning process is gone' {
        $p = New-Install -Name 'lock3'
        New-Item -ItemType Directory -Path $p.State -Force | Out-Null
        # PID 999999 is not a running process.
        Set-Content -LiteralPath $p.LockFile -Encoding UTF8 -Value (@{
            processId = 999999; host = 'test'; takenUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Compress)
        Enter-DevSetupBootLock -Path $p.LockFile -WaitSeconds 3 -StaleMinutes 60 | Should -BeTrue
    }

    It 'breaks an unreadable lock left by a crashed writer' {
        $p = New-Install -Name 'lock4'
        New-Item -ItemType Directory -Path $p.State -Force | Out-Null
        Set-Content -LiteralPath $p.LockFile -Value 'garbage' -Encoding UTF8
        Enter-DevSetupBootLock -Path $p.LockFile -WaitSeconds 3 -StaleMinutes 60 | Should -BeTrue
    }

    It 'breaks a lock that is older than StaleMinutes even if the PID is alive' {
        $p = New-Install -Name 'lock5'
        New-Item -ItemType Directory -Path $p.State -Force | Out-Null
        Set-Content -LiteralPath $p.LockFile -Encoding UTF8 -Value (@{
            processId = $PID; host = 'test'; takenUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Compress)
        (Get-Item -LiteralPath $p.LockFile).LastWriteTime = (Get-Date).AddHours(-2)
        Enter-DevSetupBootLock -Path $p.LockFile -WaitSeconds 3 -StaleMinutes 15 | Should -BeTrue
    }

    It 'records the owning process id' {
        $p = New-Install -Name 'lock6'
        Enter-DevSetupBootLock -Path $p.LockFile -WaitSeconds 2 | Out-Null
        $info = Get-Content -LiteralPath $p.LockFile -Raw | ConvertFrom-Json
        $info.processId | Should -Be $PID
        Exit-DevSetupBootLock -Path $p.LockFile
    }
}

Describe 'Package validation (Part F)' {
    It 'accepts a well-formed package' {
        $pkg = New-TestPackage -Root (Join-Path $TestDrive 'pv1') -Version '1.0.0'
        (Test-DevSetupBootPackage -PackageDir $pkg -ExpectedVersion '1.0.0').IsValid | Should -BeTrue
    }
    It 'rejects a checksum mismatch' {
        $pkg = New-TestPackage -Root (Join-Path $TestDrive 'pv2') -Version '1.0.0' -BreakChecksum
        $r = Test-DevSetupBootPackage -PackageDir $pkg -ExpectedVersion '1.0.0'
        $r.IsValid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'mismatch|checksum list'
    }
    It 'rejects a checksum list that does not match the manifest hash' {
        $pkg = New-TestPackage -Root (Join-Path $TestDrive 'pv3') -Version '1.0.0' -BreakManifestHash
        $r = Test-DevSetupBootPackage -PackageDir $pkg -ExpectedVersion '1.0.0'
        $r.IsValid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'does not match the hash pinned'
    }
    It 'rejects a version that does not match the directory' {
        $pkg = New-TestPackage -Root (Join-Path $TestDrive 'pv4') -Version '1.0.0'
        (Test-DevSetupBootPackage -PackageDir $pkg -ExpectedVersion '2.0.0').IsValid | Should -BeFalse
    }
    It 'rejects a missing manifest' {
        $pkg = New-TestPackage -Root (Join-Path $TestDrive 'pv5') -Version '1.0.0'
        Remove-Item -LiteralPath (Join-Path $pkg 'manifest.json') -Force
        (Test-DevSetupBootPackage -PackageDir $pkg -ExpectedVersion '1.0.0').IsValid | Should -BeFalse
    }
    It 'rejects an injected file that is not listed' {
        $pkg = New-TestPackage -Root (Join-Path $TestDrive 'pv6') -Version '1.0.0'
        Set-Content -LiteralPath (Join-Path $pkg 'content/sneaky.ps1') -Value 'whoami' -Encoding UTF8
        $r = Test-DevSetupBootPackage -PackageDir $pkg -ExpectedVersion '1.0.0'
        $r.IsValid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'Unlisted file'
    }
    It 'rejects invalid JSON in the manifest' {
        $pkg = New-TestPackage -Root (Join-Path $TestDrive 'pv7') -Version '1.0.0'
        Set-Content -LiteralPath (Join-Path $pkg 'manifest.json') -Value '{ not json' -Encoding UTF8
        (Test-DevSetupBootPackage -PackageDir $pkg -ExpectedVersion '1.0.0').IsValid | Should -BeFalse
    }
}

Describe 'Install, activate and roll back (Parts F / G)' {
    It 'activates a good package and records the previous version' {
        $p = New-Install -Name 'act1'
        $pkgRoot = Join-Path $TestDrive 'act1-pkgs'
        $v1 = New-TestPackage -Root $pkgRoot -Version '1.0.0'
        $v2 = New-TestPackage -Root $pkgRoot -Version '1.1.0'

        (Install-DevSetupBootVersion -Paths $p -PackageDir $v1 -Version '1.0.0' -Confirm:$false).Succeeded | Should -BeTrue
        (Install-DevSetupBootVersion -Paths $p -PackageDir $v2 -Version '1.1.0' -Confirm:$false).Succeeded | Should -BeTrue

        $s = Get-DevSetupBootState -StateFile $p.StateFile
        $s.version | Should -Be '1.1.0'
        $s.previousVersion | Should -Be '1.0.0'
        Test-Path -LiteralPath (Join-Path $p.Versions '1.0.0') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $p.Versions '1.1.0') | Should -BeTrue
    }

    It 'leaves the active version untouched when the new package is corrupt' {
        $p = New-Install -Name 'act2'
        $pkgRoot = Join-Path $TestDrive 'act2-pkgs'
        $good = New-TestPackage -Root $pkgRoot -Version '1.0.0'
        Install-DevSetupBootVersion -Paths $p -PackageDir $good -Version '1.0.0' -Confirm:$false | Out-Null

        $bad = New-TestPackage -Root $pkgRoot -Version '1.1.0' -BreakChecksum
        $r = Install-DevSetupBootVersion -Paths $p -PackageDir $bad -Version '1.1.0' -Confirm:$false
        $r.Succeeded | Should -BeFalse

        $s = Get-DevSetupBootState -StateFile $p.StateFile
        $s.version | Should -Be '1.0.0'
        Test-Path -LiteralPath (Join-Path $p.Versions '1.1.0') | Should -BeFalse
    }

    It 'rolls back when the staged version fails its self-test' {
        $p = New-Install -Name 'act3'
        $pkgRoot = Join-Path $TestDrive 'act3-pkgs'
        Install-DevSetupBootVersion -Paths $p -PackageDir (New-TestPackage -Root $pkgRoot -Version '1.0.0') -Version '1.0.0' -Confirm:$false | Out-Null

        $broken = New-TestPackage -Root $pkgRoot -Version '1.1.0' -BrokenSyntax
        $r = Install-DevSetupBootVersion -Paths $p -PackageDir $broken -Version '1.1.0' -Confirm:$false
        $r.Succeeded | Should -BeFalse
        (Get-DevSetupBootState -StateFile $p.StateFile).version | Should -Be '1.0.0'
    }

    It 'records a failed version so it is not retried in a loop' {
        $p = New-Install -Name 'act4'
        $pkgRoot = Join-Path $TestDrive 'act4-pkgs'
        Install-DevSetupBootVersion -Paths $p -PackageDir (New-TestPackage -Root $pkgRoot -Version '1.0.0') -Version '1.0.0' -Confirm:$false | Out-Null
        Install-DevSetupBootVersion -Paths $p -PackageDir (New-TestPackage -Root $pkgRoot -Version '1.1.0' -BreakChecksum) -Version '1.1.0' -Confirm:$false | Out-Null

        $s = Get-DevSetupBootState -StateFile $p.StateFile
        $s.failedVersions | Should -Contain '1.1.0'

        # And the decision function then refuses to try it again.
        (Get-DevSetupBootDecision -InstalledVersion $s.version -ChannelVersion '1.1.0' `
            -MinimumSupportedVersion '1.0.0' -FailedVersions @($s.failedVersions)).Action | Should -Be 'none'
    }

    It 'clears the failed mark once the version installs successfully' {
        $p = New-Install -Name 'act5'
        $pkgRoot = Join-Path $TestDrive 'act5-pkgs'
        Install-DevSetupBootVersion -Paths $p -PackageDir (New-TestPackage -Root $pkgRoot -Version '1.1.0' -BreakChecksum) -Version '1.1.0' -Confirm:$false | Out-Null
        (Get-DevSetupBootState -StateFile $p.StateFile).failedVersions | Should -Contain '1.1.0'

        Remove-Item -LiteralPath (Join-Path $pkgRoot '1.1.0') -Recurse -Force
        $fixed = New-TestPackage -Root $pkgRoot -Version '1.1.0'
        Install-DevSetupBootVersion -Paths $p -PackageDir $fixed -Version '1.1.0' -Confirm:$false | Out-Null
        (Get-DevSetupBootState -StateFile $p.StateFile).failedVersions | Should -Not -Contain '1.1.0'
    }

    It 'leaves no staging directory behind after a failure' {
        $p = New-Install -Name 'act6'
        $pkgRoot = Join-Path $TestDrive 'act6-pkgs'
        Install-DevSetupBootVersion -Paths $p -PackageDir (New-TestPackage -Root $pkgRoot -Version '1.0.0' -BreakChecksum) -Version '1.0.0' -Confirm:$false | Out-Null
        if (Test-Path -LiteralPath $p.Staging) {
            @(Get-ChildItem -LiteralPath $p.Staging -Directory).Count | Should -Be 0
        }
    }

    It 'changes nothing under -WhatIf' {
        $p = New-Install -Name 'act7'
        $pkg = New-TestPackage -Root (Join-Path $TestDrive 'act7-pkgs') -Version '1.0.0'
        (Install-DevSetupBootVersion -Paths $p -PackageDir $pkg -Version '1.0.0' -WhatIf).Succeeded | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $p.Versions '1.0.0') | Should -BeFalse
    }

    It 'reports the active module path' {
        $p = New-Install -Name 'act8'
        $pkg = New-TestPackage -Root (Join-Path $TestDrive 'act8-pkgs') -Version '1.0.0'
        Install-DevSetupBootVersion -Paths $p -PackageDir $pkg -Version '1.0.0' -Confirm:$false | Out-Null
        (Get-DevSetupBootActiveModulePath -Paths $p) | Should -Match 'PythonVenvAutomation\.psd1$'
    }
}

Describe 'Version retention' {
    It 'keeps the newest N plus the active and previous versions' {
        $p = New-Install -Name 'keep1'
        $pkgRoot = Join-Path $TestDrive 'keep1-pkgs'
        foreach ($v in '1.0.0', '1.1.0', '1.2.0', '1.3.0', '1.4.0') {
            Install-DevSetupBootVersion -Paths $p -PackageDir (New-TestPackage -Root $pkgRoot -Version $v) -Version $v -Confirm:$false | Out-Null
        }
        Remove-DevSetupBootOldVersion -Paths $p -Keep 2 -Confirm:$false
        $left = @(Get-ChildItem -LiteralPath $p.Versions -Directory | ForEach-Object Name)
        $left | Should -Contain '1.4.0'
        $left | Should -Contain '1.3.0'
        $left | Should -Not -Contain '1.0.0'
    }
}

Describe 'Architectural boundary (Part D)' {
    It 'the bootstrap contains no project-level concepts' {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'PythonVenvAutomation/templates/DevSetup.Bootstrap.ps1') -Raw
        # Strip comments: the boundary rule itself is documented in the header.
        $code = ($text -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        # NOTE: a bare 'venv' would match the module name PythonVenvAutomation,
        # so the assertion targets the .venv directory concept instead.
        foreach ($forbidden in 'pyproject', 'poetry', 'uv\.lock', 'requires-python',
                               'VSCode', 'Tcl', '\.venv', 'dependency-groups', 'Start-Setup') {
            $code | Should -Not -Match $forbidden
        }
    }

    It 'the bootstrap does not import the DevSetup module' {
        $code = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'PythonVenvAutomation/templates/DevSetup.Bootstrap.ps1') -Raw
        $code | Should -Not -Match 'Import-Module\s+PythonVenvAutomation'
    }
}
