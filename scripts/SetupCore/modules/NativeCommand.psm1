#Requires -Version 5.1
# =============================================================================
# Module  : NativeCommand.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'CommandLog.psm1') -Force -DisableNameChecking -ErrorAction Stop

<#
.SYNOPSIS
    Native process execution helpers for setup modules.

.DESCRIPTION
    Provides a single entry point for invoking native executables while
    capturing stdout/stderr, preserving console output behavior, and treating
    success strictly by process exit code.
#>

<#
.SYNOPSIS
    Executes a native command and returns a structured result object.

.DESCRIPTION
    Starts the target process with output redirection to temporary files,
    reads those files after completion, mirrors output to the host unless
    -Quiet is used, and returns an object with ExitCode, Succeeded, StdOut,
    StdErr, and ErrorText.

.PARAMETER Executable
    Full path or command name of the native executable to run.

.PARAMETER Arguments
    Command-line arguments passed to the executable.

.PARAMETER WorkingDirectory
    Optional working directory for process execution.

.PARAMETER Quiet
    Suppresses host output while still capturing stdout/stderr.

.PARAMETER ThrowOnError
    Throws when the command exits with a non-zero exit code.

.PARAMETER FailureMessage
    Prefix used for thrown exceptions when -ThrowOnError is specified.

.OUTPUTS
    PSCustomObject with ExitCode, Succeeded, StdOut, StdErr, and ErrorText.
#>
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory=$true)][string] $Executable,
        [Parameter()][string[]] $Arguments = @(),
        [Parameter()][string] $WorkingDirectory,
        [switch] $Quiet,
        [switch] $NoLog,
        [switch] $ThrowOnError,
        [string] $FailureMessage = 'Native command failed.'
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    $exitCode = $null
    $stdoutText = ''
    $stderrText = ''

    try {
        # Start-Process -ArgumentList joins array elements with a single space
        # and does NOT quote elements that contain whitespace.  Any path such as
        # "C:\Program Files\Python310\python.exe" would be split into multiple
        # tokens by the target process's argument parser (e.g. Poetry sees
        # "C:\Program" and "Files\Python310\python.exe" as separate arguments).
        # We quote every whitespace-containing element here so callers never need
        # to pre-quote paths.
        $safeArgs = @($Arguments | ForEach-Object {
            if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        })

        $startParams = @{
            FilePath = $Executable
            ArgumentList = $safeArgs
            NoNewWindow = $true
            Wait = $true
            PassThru = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
            ErrorAction = 'Stop'
        }
        if (-not $NoLog) {
            Write-CommandLog -Executable $Executable -Arguments $Arguments -WorkingDirectory $WorkingDirectory
        }
        if ($WorkingDirectory) {
            $startParams.WorkingDirectory = $WorkingDirectory
        }

        $proc = Start-Process @startParams

        if (Test-Path $stdoutPath -PathType Leaf) {
            $raw = Get-Content -Path $stdoutPath -Raw
            if ($raw) { $stdoutText = $raw }
        }
        if (Test-Path $stderrPath -PathType Leaf) {
            $raw = Get-Content -Path $stderrPath -Raw
            if ($raw) { $stderrText = $raw }
        }

        if (-not $Quiet) {
            if ($stdoutText) { $stdoutText | Out-Host }
            if ($stderrText) { $stderrText | Out-Host }
        }

        $exitCode = [int]$proc.ExitCode
    } catch {
        $msg = "Failed to start native command '$Executable': $($_.Exception.Message)"
        if ($ThrowOnError) {
            throw $msg
        }

        return [pscustomobject]@{
            ExitCode  = 1
            Succeeded = $false
            StdOut    = $stdoutText
            StdErr    = $stderrText
            ErrorText = $msg
        }
    } finally {
        if (Test-Path $stdoutPath -PathType Leaf) { Remove-Item $stdoutPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $stderrPath -PathType Leaf) { Remove-Item $stderrPath -Force -ErrorAction SilentlyContinue }
    }

    $result = [pscustomobject]@{
        ExitCode  = $exitCode
        Succeeded = ($exitCode -eq 0)
        StdOut    = $stdoutText
        StdErr    = $stderrText
        ErrorText = $null
    }

    if ($ThrowOnError -and -not $result.Succeeded) {
        $details = $result.StdErr
        if (-not $details) {
            $details = $result.StdOut
        }

        $suffix = ''
        if ($details) {
            $suffix = "`n$($details.Trim())"
        }

        throw ("{0} (exit code {1}){2}" -f $FailureMessage, $result.ExitCode, $suffix)
    }

    return $result
}

Export-ModuleMember -Function Invoke-NativeCommand
