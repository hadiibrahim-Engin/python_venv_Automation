#Requires -Version 5.1
# =============================================================================
# Module  : Compat.psm1
# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    PowerShell version compatibility shims for the setup pipeline.

.DESCRIPTION
    Centralises every feature that differs between PS 5.1 and PS 7.x so the
    rest of the codebase stays version-agnostic.

    This module must be imported FIRST (before any other SetupCore module).

    Rule for adding a new shim:
      - SYNTAX additions (tokenised before any branch can guard them, e.g. ?.
        ??, ? :, &&, ||): wrap in [scriptblock]::Create() so PS 5.1 never sees
        the tokens.  Expose a normal function that callers invoke.
      - API-only additions (new cmdlets, parameters, .NET types): a plain
        version-check inside the function body is sufficient.

    Current shims
    -------------
    Get-CommandSource  -- null-safe command-path lookup
                          PS 7.1+  : (Get-Command name)?.Source
                          PS 5.1/6 : explicit null check
#>

# ---------------------------------------------------------------------------
# Internal scriptblocks - resolved once at module-load time, not per-call.
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion -ge [Version]'7.1') {
    $script:_impl_GetCommandSource = [scriptblock]::Create(
        'param([string]$Name) (Get-Command $Name -ErrorAction SilentlyContinue)?.Source'
    )
} else {
    $script:_impl_GetCommandSource = {
        param([string]$Name)
        $cmd = Get-Command $Name -ErrorAction SilentlyContinue
        if ($cmd) { $cmd.Source } else { $null }
    }
}

# ---------------------------------------------------------------------------
# Exported helpers
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Returns the full path of a named command, or $null when not found.

.DESCRIPTION
    Drop-in replacement for the common pattern:
        (Get-Command 'foo' -ErrorAction SilentlyContinue)?.Source
    Safe on PS 5.1 through PS 7.x.

.PARAMETER Name
    The command name to resolve (e.g. 'python', 'uv', 'pipx').

.OUTPUTS
    String path, or $null.

.EXAMPLE
    $exe = Get-CommandSource 'python'
    if (-not $exe) { throw 'Python not on PATH.' }
#>
function Get-CommandSource {
    param([Parameter(Mandatory)][string] $Name)
    & $script:_impl_GetCommandSource $Name
}

<#
.SYNOPSIS
    Returns $true when the current process is running on Windows.

.DESCRIPTION
    Centralises the $env:OS -eq 'Windows_NT' check so the rest of the
    codebase avoids copy-pasting this platform guard.
#>
function Get-IsWindows {
    return $env:OS -eq 'Windows_NT'
}

function Get-IsLinux {
    # $IsLinux is a PS 6+ automatic variable; always $null on PS 5.1 (Windows-only)
    return ($IsLinux -eq $true)
}

<#
.SYNOPSIS
    Returns the path to the Python executable inside a virtual environment.

.DESCRIPTION
    Encapsulates the Windows / POSIX path difference so callers need not
    inline the platform check everywhere.

        Windows : <VenvDir>\Scripts\python.exe
        POSIX   : <VenvDir>/bin/python

.PARAMETER VenvDir
    Absolute path to the .venv directory.

.OUTPUTS
    String path.
#>
function Get-VenvPythonExe {
    param([Parameter(Mandatory=$true)][string] $VenvDir)
    if (Get-IsWindows) {
        Join-Path $VenvDir 'Scripts\python.exe'
    } else {
        Join-Path $VenvDir 'bin/python'
    }
}

Export-ModuleMember -Function Get-CommandSource, Get-IsWindows, Get-IsLinux, Get-VenvPythonExe