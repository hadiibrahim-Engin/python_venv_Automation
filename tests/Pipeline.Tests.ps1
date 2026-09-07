#Requires -Version 5.1
# Build/version/publish-script tests. These are static/structural checks; no
# package is actually published to a remote feed.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Version single-source-of-truth' {
    It 'VERSION matches the manifest ModuleVersion' {
        $v = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw).Trim()
        $m = (Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'PythonVenvAutomation\PythonVenvAutomation.psd1')).ModuleVersion
        "$m" | Should -Be $v
    }

    It 'Build.ps1 fails fast when VERSION and the manifest disagree' {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("ver-mismatch-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $work 'PythonVenvAutomation') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $work 'scripts4PythonAutomation') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'PythonVenvAutomation\PythonVenvAutomation.psd1') -Destination (Join-Path $work 'PythonVenvAutomation') -Force
        Set-Content -LiteralPath (Join-Path $work 'VERSION') -Value '9.9.9'
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'build') -Destination $work -Recurse -Force

        $pwshExe = (Get-Process -Id $PID).Path
        $out = & $pwshExe -NoProfile -File (Join-Path $work 'build\Build.ps1') 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out -join "`n") | Should -Match 'mismatch'

        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Build output' {
    It 'writes the package into artifacts/' {
        $pwshExe = (Get-Process -Id $PID).Path
        $out = & $pwshExe -NoProfile -File (Join-Path $RepoRoot 'build\Build.ps1') 2>&1
        $LASTEXITCODE | Should -Be 0
        $artifacts = Join-Path $RepoRoot 'artifacts'
        Test-Path $artifacts | Should -BeTrue
        @(Get-ChildItem -Path $artifacts -Filter '*.zip' -Recurse).Count | Should -BeGreaterThan 0
    }
}

Describe 'Publish.ps1 is backend-agnostic' {
    BeforeAll {
        $script:PublishText = Get-Content -LiteralPath (Join-Path $RepoRoot 'build\Publish.ps1') -Raw
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'build\Publish.ps1'), [ref]$null, [ref]$null)
    }

    It 'requires configurable RepositoryName and RepositoryUri parameters' {
        $names = $Ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        $names | Should -Contain 'RepositoryName'
        $names | Should -Contain 'RepositoryUri'
    }

    It 'accepts an ApiKey and Prerelease switch' {
        $names = $Ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        $names | Should -Contain 'ApiKey'
        $names | Should -Contain 'Prerelease'
    }

    It 'contains no hardcoded Azure DevOps or GitHub Packages URLs' {
        $PublishText | Should -Not -Match 'pkgs\.dev\.azure\.com'
        $PublishText | Should -Not -Match 'nuget\.pkg\.github\.com'
    }

    It 'fails closed when credentials are missing for a hosted feed' {
        $PublishText | Should -Match 'Refusing to publish without credentials'
    }
}

Describe 'No committed secrets' {
    BeforeAll {
        $script:AzureYaml = Get-Content -LiteralPath (Join-Path $RepoRoot 'azure-pipelines.yml') -Raw
        $script:GhYaml    = Get-Content -LiteralPath (Join-Path $RepoRoot '.github/workflows/publish.yml') -Raw
    }

    It 'the Azure pipeline contains no token literals' {
        foreach ($pattern in 'personalAccessToken', 'ghp_[A-Za-z0-9]{16,}', 'password\s*[:=]\s*\S', ':\S+@dev\.azure\.com') {
            $script:AzureYaml | Should -Not -Match $pattern
        }
    }

    It 'the GitHub workflow contains no token literals' {
        foreach ($pattern in 'personalAccessToken', 'ghp_[A-Za-z0-9]{16,}', ':\S+@github\.com') {
            $script:GhYaml | Should -Not -Match $pattern
        }
    }

    It 'pushes with the Build Service identity rather than a PAT' {
        # persistCredentials hands git the pipeline identity, which is what
        # makes a PAT unnecessary for the distribution push.
        $script:AzureYaml | Should -Match 'persistCredentials:\s*true'
    }

    It 'excludes the distribution branch from its own trigger' {
        # Without this, publishing would re-trigger the pipeline in a loop.
        $script:AzureYaml | Should -Match '(?s)trigger:.*exclude:.*distribution'
    }

    It 'publishes to the distribution branch, not to a package feed' {
        $script:AzureYaml | Should -Match 'Publish-Distribution\.ps1'
        $script:AzureYaml | Should -Not -Match 'nuget/v3/index\.json'
    }
}
