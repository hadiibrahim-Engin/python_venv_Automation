#Requires -Version 5.1
# =============================================================================
# Module  : NativeCommand.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'CommandLog.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop

<#
.SYNOPSIS
    Native process execution helpers for setup modules.

.DESCRIPTION
    Provides a single entry point for invoking native executables.

    Two execution modes:

      Default (capture mode)
          Uses System.Diagnostics.Process with async ReadToEndAsync() so that
          stdout and stderr are captured to strings entirely in memory — no
          temporary files are created or read.  Output is mirrored to the host
          after the process exits unless -Quiet is specified.
          Use for short-lived probes (python --version, uv --version, etc.).

      PassThrough mode  (-PassThrough)
          Runs Start-Process without any output redirection so the child process
          inherits the parent's console handles.  Progress bars, download
          percentages, and streaming log lines from uv/poetry/pip are shown in
          real time.  StdOut / StdErr in the result object are empty strings
          because output is never captured — only the exit code is returned.
          Use for long-running install / sync / update operations.
#>

function Invoke-NativeCommand {
<#
.SYNOPSIS
    Executes a native command and returns a structured result object.

.PARAMETER Executable
    Full path or command name of the native executable to run.

.PARAMETER Arguments
    Command-line arguments passed to the executable.

.PARAMETER WorkingDirectory
    Optional working directory for process execution.

.PARAMETER Quiet
    Suppresses host output while still capturing stdout/stderr (capture mode).
    Has no effect in -PassThrough mode (output is never captured there).

.PARAMETER PassThrough
    Runs without output redirection so console output streams live.
    Suitable for uv sync, poetry install, pip install, etc.
    StdOut / StdErr fields in the result object will be empty.

.PARAMETER ThrowOnError
    Throws when the command exits with a non-zero exit code.

.PARAMETER FailureMessage
    Prefix used for thrown exceptions when -ThrowOnError is specified.

.OUTPUTS
    PSCustomObject with ExitCode, Succeeded, StdOut, StdErr, and ErrorText.
#>
    param(
        [Parameter(Mandatory=$true)][string] $Executable,
        [Parameter()][string[]] $Arguments       = @(),
        [Parameter()][string]   $WorkingDirectory,
        [switch] $Quiet,
        [switch] $NoLog,
        [switch] $PassThrough,
        [switch] $ThrowOnError,
        [string] $FailureMessage = 'Native command failed.'
    )

    if (-not $NoLog) {
        Write-CommandLog -Executable $Executable -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    }

    # Build a properly quoted argument string (required for ProcessStartInfo.Arguments
    # on .NET Framework / PowerShell 5.1 which lacks ArgumentList on ProcessStartInfo).
    $safeArgs = @($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    })
    $argString = if ($safeArgs.Count -gt 0) { $safeArgs -join ' ' } else { '' }

    # ------------------------------------------------------------------
    # PassThrough mode: no output redirection → live console streaming.
    # ------------------------------------------------------------------
    if ($PassThrough) {
        $startParams = @{
            FilePath    = $Executable
            NoNewWindow = $true
            Wait        = $true
            PassThru    = $true
            ErrorAction = 'Stop'
        }
        # Pass the pre-quoted string as ArgumentList so Start-Process
        # does not add an extra layer of quoting.
        if ($argString) { $startParams.ArgumentList = $argString }
        if ($WorkingDirectory) { $startParams.WorkingDirectory = $WorkingDirectory }

        $exitCode = 1
        try {
            $proc     = Start-Process @startParams
            $exitCode = [int]$proc.ExitCode
        } catch {
            $msg = "Failed to start native command '$Executable': $($_.Exception.Message)"
            if ($ThrowOnError) { throw $msg }
            return [pscustomobject]@{
                ExitCode  = 1
                Succeeded = $false
                StdOut    = ''
                StdErr    = ''
                ErrorText = $msg
            }
        }

        $result = [pscustomobject]@{
            ExitCode  = $exitCode
            Succeeded = ($exitCode -eq 0)
            StdOut    = ''
            StdErr    = ''
            ErrorText = $null
        }

        if ($ThrowOnError -and -not $result.Succeeded) {
            throw ("{0} (exit code {1})" -f $FailureMessage, $exitCode)
        }
        return $result
    }

    # ------------------------------------------------------------------
    # Capture mode: async in-memory stdout/stderr — no temp files.
    # ------------------------------------------------------------------
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $Executable
    $psi.Arguments              = $argString
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc       = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $exitCode   = 1
    $stdoutText = ''
    $stderrText = ''

    try {
        [void]$proc.Start()

        # Read both streams concurrently.  ReadToEndAsync() must be called
        # BEFORE WaitForExit() to prevent a deadlock if one buffer fills while
        # the other is not yet consumed.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $proc.WaitForExit()

        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $stderrText = $stderrTask.GetAwaiter().GetResult()
        $exitCode   = $proc.ExitCode
    } catch {
        $msg = "Failed to start native command '$Executable': $($_.Exception.Message)"
        if ($ThrowOnError) { throw $msg }
        return [pscustomobject]@{
            ExitCode  = 1
            Succeeded = $false
            StdOut    = $stdoutText
            StdErr    = $stderrText
            ErrorText = $msg
        }
    } finally {
        $proc.Dispose()
    }

    if (-not $Quiet) {
        if ($stdoutText) { Write-Host $stdoutText }
        if ($stderrText) { Write-Host $stderrText }
    }

    $result = [pscustomobject]@{
        ExitCode  = $exitCode
        Succeeded = ($exitCode -eq 0)
        StdOut    = $stdoutText
        StdErr    = $stderrText
        ErrorText = $null
    }

    if ($ThrowOnError -and -not $result.Succeeded) {
        $details = if ($stderrText) { $stderrText } else { $stdoutText }
        $suffix  = if ($details) { "`n$($details.Trim())" } else { '' }
        throw ("{0} (exit code {1}){2}" -f $FailureMessage, $exitCode, $suffix)
    }

    return $result
}

Export-ModuleMember -Function Invoke-NativeCommand
