#Requires -Version 5.1
# =============================================================================
# Module  : CommandLog.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Command execution logging utilities.

.DESCRIPTION
    Provides compact, readable logging of native commands and their arguments
    before execution.
#>

<#
.SYNOPSIS
    Logs a command execution in compact format.

.DESCRIPTION
    Displays the executable name and shortened arguments to show what command
    is about to be run. Long argument values are truncated with ellipsis.
#>
function Write-CommandLog {
    param(
        [Parameter(Mandatory=$true)][string] $Executable,
        [Parameter()][string[]] $Arguments = @(),
        [Parameter()][string] $WorkingDirectory
    )
    
    $exeName = Split-Path $Executable -Leaf
    $argString = ''
    
    if ($Arguments.Count -gt 0) {
        $displayArgs = @()
        foreach ($arg in $Arguments) {
            if ($arg.Length -gt 30) {
                $displayArgs += ($arg.Substring(0, 27) + '...')
            } else {
                $displayArgs += $arg
            }
        }
        $argString = ' ' + ($displayArgs -join ' ')
    }
    
    $location = if ($WorkingDirectory) { " (cwd: $(Split-Path $WorkingDirectory -Leaf))" } else { '' }
    Write-Host ("[CMD] {0}{1}{2}" -f $exeName, $argString, $location) -ForegroundColor DarkCyan
}

Export-ModuleMember -Function Write-CommandLog
