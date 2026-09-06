#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulesRoot = Join-Path $RepoRoot 'scripts4PythonAutomation\SetupCore\modules'

    Import-Module (Join-Path $ModulesRoot 'Constants.psm1') -Force
    Import-Module (Join-Path $ModulesRoot 'Errors.psm1') -Force
    Import-Module (Join-Path $ModulesRoot 'SetupPipeline.psm1') -Force
}

AfterAll {
    Remove-Module SetupPipeline -Force -ErrorAction SilentlyContinue
    Remove-Module Errors -Force -ErrorAction SilentlyContinue
    Remove-Module Constants -Force -ErrorAction SilentlyContinue
}

Describe 'Constants.psm1' {
    It 'returns centralized Git defaults' {
        $constants = Get-SetupConstants
        $constants.Git.FetchTimeoutSeconds | Should -Be 10
        $constants.Git.DefaultPullStrategy | Should -Be 'SkipIfDirty'
        $constants.Git.RemoteName | Should -Be 'origin'
    }

    It 'returns an independent copy on every call' {
        $first = Get-SetupConstants
        $second = Get-SetupConstants
        $first.Git.FetchTimeoutSeconds = 99
        $second.Git.FetchTimeoutSeconds | Should -Be 10
    }
}

Describe 'SetupException' {
    It 'preserves structured error metadata' {
        $exception = InModuleScope SetupPipeline {
            New-SetupException -Message 'Failure' -ErrorCode 'TEST_FAILURE' -Step 'TEST' -Context @{ Project = 'demo' }
        }
        $exception.GetType().Name | Should -Be 'SetupException'
        $exception.ErrorCode | Should -Be 'TEST_FAILURE'
        $exception.Step | Should -Be 'TEST'
        $exception.Context.Project | Should -Be 'demo'
    }

    It 'wraps native exceptions and preserves inner exception' {
        $wrapped = InModuleScope SetupPipeline {
            try { throw [System.InvalidOperationException]::new('native failure') }
            catch { ConvertTo-SetupException -ErrorRecord $_ -ErrorCode 'WRAPPED' -Step 'UNIT' }
        }
        $wrapped.ErrorCode | Should -Be 'WRAPPED'
        $wrapped.InnerException.Message | Should -Be 'native failure'
    }
}

Describe 'SetupPipeline primitives' {
    It 'executes steps in order' {
        $script:order = New-Object System.Collections.Generic.List[string]
        $step1 = New-SetupPipelineStep -Name 'ONE' -Module 'Test' -Message 'one' -Action { $script:order.Add('ONE') }
        $step2 = New-SetupPipelineStep -Name 'TWO' -Module 'Test' -Message 'two' -Action { $script:order.Add('TWO') }
        $results = Invoke-SetupPipeline -Steps @($step1, $step2)
        @($script:order) | Should -Be @('ONE', 'TWO')
        @($results).Count | Should -Be 2
        $results[0].Status | Should -Be 'OK'
        $results[1].Status | Should -Be 'OK'
    }

    It 'skips mutating steps in dry-run but executes read-only steps' {
        $script:mutated = $false
        $script:read = $false
        $readStep = New-SetupPipelineStep -Name 'READ' -Module 'Test' -Message 'read' -ReadOnly -Action { $script:read = $true }
        $writeStep = New-SetupPipelineStep -Name 'WRITE' -Module 'Test' -Message 'write' -Action { $script:mutated = $true }
        $results = Invoke-SetupPipeline -Steps @($readStep, $writeStep) -DryRun
        $script:read | Should -BeTrue
        $script:mutated | Should -BeFalse
        $results[0].Status | Should -Be 'OK'
        $results[1].Status | Should -Be 'SKIPPED'
    }

    It 'wraps mandatory failures as SetupException' {
        $step = New-SetupPipelineStep -Name 'FAIL' -Module 'Test' -Message 'failure' -ErrorCode 'PIPE_TEST' -Action { throw 'boom' }
        try {
            Invoke-SetupPipelineStep -Step $step
            throw 'Expected pipeline step to fail.'
        }
        catch {
            $_.Exception.GetType().Name | Should -Be 'SetupException'
            $_.Exception.ErrorCode | Should -Be 'PIPE_TEST'
            $_.Exception.Step | Should -Be 'FAIL'
        }
    }

    It 'continues after optional-step failure' {
        $optional = New-SetupPipelineStep -Name 'OPTIONAL' -Module 'Test' -Message 'optional' -Mandatory:$false -Action { throw 'optional failure' }
        $result = Invoke-SetupPipelineStep -Step $optional
        $result.Status | Should -Be 'WARN'
        $result.Error.GetType().Name | Should -Be 'SetupException'
    }
}
