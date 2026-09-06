#Requires -Version 5.1
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\Logging.psm1'
    Import-Module $modulePath -Force
}
AfterAll { Remove-Module Logging -Force -ErrorAction SilentlyContinue }

Describe 'Structured logging' {
    It 'creates a correlation id and writes NDJSON events' {
        $log = Join-Path $TestDrive 'setup.json'
        $id = Start-StructuredLogSession -LogLevel INFO -LogFilePath $log
        $id | Should -Not -BeNullOrEmpty
        Write-StructuredLog -Level INFO -Step TEST -Message 'hello' -Module Unit -Context @{ Value = 1 } -NoConsole
        $lines = @(Get-Content -LiteralPath $log | Where-Object { $_.Trim() })
        $lines.Count | Should -BeGreaterThan 1
        $event = $lines[-1] | ConvertFrom-Json
        $event.Level | Should -Be 'INFO'
        $event.Step | Should -Be 'TEST'
        $event.CorrelationId | Should -Be $id
        $event.Context.Value | Should -Be 1
    }

    It 'filters events below the configured level' {
        $log = Join-Path $TestDrive 'warn.json'
        Start-StructuredLogSession -LogLevel WARN -LogFilePath $log | Out-Null
        Write-StructuredLog -Level INFO -Step TEST -Message 'hidden' -NoConsole
        Write-StructuredLog -Level ERROR -Step TEST -Message 'visible' -NoConsole
        $events = @(Get-Content -LiteralPath $log | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        @($events | Where-Object Message -eq 'hidden').Count | Should -Be 0
        @($events | Where-Object Message -eq 'visible').Count | Should -Be 1
    }
}
