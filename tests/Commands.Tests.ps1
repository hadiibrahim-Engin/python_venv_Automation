#Requires -Version 5.1
<#
    Part AC "Commands":
      * doctor mutates nothing
      * repair applies only safe fixes
      * a normal devsetup run does NOT upgrade all dependencies
        (covered in DependencySemantics.Tests.ps1)
      * the support bundle redacts secrets
#>
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    foreach ($m in 'Errors', 'Constants', 'UI', 'Logging', 'Compat', 'Versioning', 'TomlParser',
                   'Config', 'Toml', 'Redaction', 'SupportCodes', 'PyProjectHealth', 'Diagnostics') {
        Import-Module (Join-Path $modules "$m.psm1") -Force -DisableNameChecking -Global
    }

    function New-CommandProject {
        param([string] $Name, [string] $Toml, [string[]] $Locks = @('uv.lock'))
        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Value $Toml -Encoding UTF8
        foreach ($l in $Locks) { Set-Content -LiteralPath (Join-Path $root $l) -Value 'lock' -Encoding UTF8 }
        Clear-PyProjectHealthCache
        return $root
    }

    function Get-TreeSnapshot {
        param([string] $Root)
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
            Sort-Object FullName |
            ForEach-Object { '{0}|{1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }

    $script:DirtyToml = @'
[project]
name = "cmddemo"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["requests>=2.31", "Requests"]

[tool.uv]
dev-dependencies = ["pytest"]
'@
}
AfterAll { Remove-Module Diagnostics -Force -ErrorAction SilentlyContinue }

Describe 'devsetup doctor mutates nothing' {
    It 'leaves every file in the project byte-identical' {
        $root = New-CommandProject -Name 'doctor-clean' -Toml $script:DirtyToml
        $before = Get-TreeSnapshot -Root $root

        Get-DevSetupDoctorReport -ProjectRoot $root | Out-Null
        Get-DevSetupDoctorReport -ProjectRoot $root | Out-Null

        (Get-TreeSnapshot -Root $root) -join "`n" | Should -Be ($before -join "`n")
    }

    It 'creates no new files (no backups, no temp files)' {
        $root = New-CommandProject -Name 'doctor-nofiles' -Toml $script:DirtyToml
        $before = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File).Count
        Get-DevSetupDoctorReport -ProjectRoot $root | Out-Null
        @(Get-ChildItem -LiteralPath $root -Recurse -Force -File).Count | Should -Be $before
    }

    It 'is stable: two runs report the same checks' {
        $root = New-CommandProject -Name 'doctor-stable' -Toml $script:DirtyToml
        $a = (Get-DevSetupDoctorReport -ProjectRoot $root).Checks | ForEach-Object { '{0}={1}' -f $_.Name, $_.Status }
        $b = (Get-DevSetupDoctorReport -ProjectRoot $root).Checks | ForEach-Object { '{0}={1}' -f $_.Name, $_.Status }
        ($a -join ',') | Should -Be ($b -join ',')
    }

    It 'reports failures for an ambiguous project' {
        $root = New-CommandProject -Name 'doctor-ambiguous' -Locks @() -Toml @'
[project]
name = "x"
version = "1.0.0"
requires-python = ">=3.11"
'@
        $r = Get-DevSetupDoctorReport -ProjectRoot $root
        $r.HasFailures | Should -BeTrue
        ($r.Checks | Where-Object Name -eq 'Paketmanager').Status | Should -Be 'FAIL'
    }

    It 'renders short output without internal module names' {
        $root = New-CommandProject -Name 'doctor-output' -Toml $script:DirtyToml
        $text = Format-DevSetupDoctorReport -Report (Get-DevSetupDoctorReport -ProjectRoot $root)
        $text | Should -Match 'DevSetup Diagnose'
        $text | Should -Not -Match 'psm1'
        $text | Should -Not -Match 'ScriptStackTrace'
    }
}

Describe 'devsetup repair applies only safe fixes' {
    It 'applies the safe fixes and reports what it changed' {
        $root = New-CommandProject -Name 'repair-safe' -Toml $script:DirtyToml
        $r = Invoke-DevSetupRepair -ProjectRoot $root -Confirm:$false
        $r.Changed | Should -BeTrue
        ($r.Applied | ForEach-Object Code) | Should -Contain 'PYPROJECT_DUPLICATE_DEPENDENCY'
        ($r.Applied | ForEach-Object Code) | Should -Contain 'PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES'
    }

    It 'never applies a NeedsDecision finding' {
        $root = New-CommandProject -Name 'repair-decision' -Locks @('poetry.lock') -Toml @'
[project]
name = "x"
version = "1.2.3"
requires-python = ">=3.11"

[tool.poetry]
name = "x"
version = "9.9.9"
'@
        $before = Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw
        $r = Invoke-DevSetupRepair -ProjectRoot $root -Confirm:$false
        $r.Changed | Should -BeFalse
        ($r.NeedsDecision | ForEach-Object Code) | Should -Contain 'PYPROJECT_METADATA_DIVERGED'
        (Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw) | Should -Be $before
    }

    It 'fails in non-interactive mode when a decision is still outstanding' {
        $root = New-CommandProject -Name 'repair-ci' -Locks @() -Toml @'
[project]
name = "x"
version = "1.0.0"
requires-python = ">=3.11"
'@
        (Invoke-DevSetupRepair -ProjectRoot $root -NonInteractive -Confirm:$false).Succeeded | Should -BeFalse
    }

    It 'succeeds in non-interactive mode when nothing needs a decision' {
        $root = New-CommandProject -Name 'repair-ci-ok' -Toml $script:DirtyToml
        (Invoke-DevSetupRepair -ProjectRoot $root -NonInteractive -Confirm:$false).Succeeded | Should -BeTrue
    }

    It 'changes nothing under -WhatIf' {
        # $WhatIfPreference does not cross module boundaries, so this pins the
        # explicit forwarding in Invoke-DevSetupRepair.
        $root = New-CommandProject -Name 'repair-whatif' -Toml $script:DirtyToml
        $before = Get-TreeSnapshot -Root $root
        $r = Invoke-DevSetupRepair -ProjectRoot $root -WhatIf
        $r.Changed | Should -BeFalse
        (Get-TreeSnapshot -Root $root) -join "`n" | Should -Be ($before -join "`n")
    }

    It 'reduces the number of findings' {
        $root = New-CommandProject -Name 'repair-reduces' -Toml $script:DirtyToml
        $r = Invoke-DevSetupRepair -ProjectRoot $root -Confirm:$false
        $r.AfterCount | Should -BeLessThan $r.BeforeCount
    }
}

Describe 'devsetup support bundle redacts secrets' {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    }

    It 'produces a zip that contains no secret values' {
        $root = New-CommandProject -Name 'support-redact' -Toml $script:DirtyToml
        Set-Content -LiteralPath (Join-Path $root '.setup-config.json') `
            -Value '{"PackageManager":"uv","AZURE_PAT":"supersecrettoken123"}' -Encoding UTF8
        $log = Join-Path $root 'run.ndjson'
        Set-Content -LiteralPath $log -Encoding UTF8 `
            -Value '{"url":"https://user:PATSECRET99@dev.azure.com/org","token":"tok-abc-123"}'

        $out = Join-Path $TestDrive 'bundles'
        $bundle = New-DevSetupSupportBundle -ProjectRoot $root -OutputDirectory $out -LogPath $log -Confirm:$false
        $bundle.Created | Should -BeTrue
        Test-Path -LiteralPath $bundle.ZipPath | Should -BeTrue

        $zip = [System.IO.Compression.ZipFile]::OpenRead($bundle.ZipPath)
        try {
            $all = foreach ($entry in $zip.Entries) {
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try { $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
            $joined = $all -join "`n"
            $joined | Should -Not -Match 'supersecrettoken123'
            $joined | Should -Not -Match 'PATSECRET99'
            $joined | Should -Not -Match 'tok-abc-123'
        } finally { $zip.Dispose() }
    }

    It 'includes the expected diagnostic files' {
        $root = New-CommandProject -Name 'support-files' -Toml $script:DirtyToml
        $bundle = New-DevSetupSupportBundle -ProjectRoot $root -OutputDirectory (Join-Path $TestDrive 'b2') -Confirm:$false
        foreach ($f in 'system.json', 'devsetup-version.json', 'health-report.json', 'pyproject-health.json', 'python-report.json', 'git-status.txt') {
            $bundle.Files | Should -Contain $f
        }
    }

    It 'creates nothing under -WhatIf' {
        $root = New-CommandProject -Name 'support-whatif' -Toml $script:DirtyToml
        $out = Join-Path $TestDrive 'b3'
        $bundle = New-DevSetupSupportBundle -ProjectRoot $root -OutputDirectory $out -WhatIf
        $bundle.Created | Should -BeFalse
        Test-Path -LiteralPath $bundle.ZipPath | Should -BeFalse
    }

    It 'leaves no staging directory behind' {
        $root = New-CommandProject -Name 'support-clean' -Toml $script:DirtyToml
        $before = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'devsetup-support-*' -Directory -ErrorAction SilentlyContinue).Count
        New-DevSetupSupportBundle -ProjectRoot $root -OutputDirectory (Join-Path $TestDrive 'b4') -Confirm:$false | Out-Null
        @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'devsetup-support-*' -Directory -ErrorAction SilentlyContinue).Count |
            Should -Be $before
    }
}
