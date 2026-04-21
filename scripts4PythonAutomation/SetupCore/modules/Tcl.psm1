#Requires -Version 5.1
# =============================================================================
# Module  : Tcl.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1') -Force -DisableNameChecking -ErrorAction Stop

<#
.SYNOPSIS
    Tcl runtime copy helper for virtual environments.
#>

<#
.SYNOPSIS
    Copies Python's tcl directory into .venv when present.

.DESCRIPTION
    Uses robocopy and treats exit codes below 8 as success, matching
    robocopy semantics for non-fatal copy differences.
#>
function Copy-TclToVenv {
    param(
        [Parameter(Mandatory=$true)][string] $PythonDir,
        [Parameter(Mandatory=$true)][string] $VenvDir
    )

    $tclSrc = Join-Path $PythonDir 'tcl'
    $tclDst = Join-Path $VenvDir 'tcl'
    if (Test-Path $tclSrc) {
        Write-Host ''
        Write-Host 'Copying tcl folder to .venv ...' -ForegroundColor Yellow

        # robocopy exit codes < 8 are non-fatal
        robocopy $tclSrc $tclDst /E /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
        if ($LASTEXITCODE -lt 8) {
            Write-Banner 'tcl folder copied to .venv.' 'SUCCESS'
        } else {
            throw ("robocopy failed (exit {0}) while copying tcl folder." -f $LASTEXITCODE)
        }
    } else {
        Write-Banner ("tcl folder not found at '{0}' -- skipping." -f $tclSrc) 'WARN'
    }
}