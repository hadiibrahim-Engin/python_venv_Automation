#Requires -Version 5.1
# =============================================================================
# Module  : UI.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Console UX helpers shared across setup modules.
#>

<#
.SYNOPSIS
    Writes a colored setup banner with severity labeling.
#>
function Write-Banner {
    param(
        [Parameter(Mandatory=$true)][string] $Message,
        [ValidateSet('INFO','SUCCESS','WARN','ERROR')]
        [string] $Type = 'INFO'
    )
    $color = switch ($Type) {
        'SUCCESS' { 'Green'  }
        'ERROR'   { 'Red'    }
        'WARN'    { 'Yellow' }
        default   { 'Cyan'   }
    }
    Write-Host ("[{0}] {1}" -f $Type, $Message) -ForegroundColor $color
}

function Write-LogStepStart {
    param(
        [Parameter(Mandatory=$true)][string] $Step,
        [Parameter(Mandatory=$true)][string] $Module,
        [Parameter(Mandatory=$true)][string] $Message
    )
    Write-Host ''
    Write-Host ('+' + ('-' * 94) + '+') -ForegroundColor DarkCyan
    Write-Host ("| [INFO]  Step: {0,-10} Module: {1,-14} {2}" -f $Step, $Module, $Message) -ForegroundColor Cyan
    Write-Host ('+' + ('-' * 94) + '+') -ForegroundColor DarkCyan
}

function Write-LogDetail {
    param(
        [Parameter(Mandatory=$true)][string] $Key,
        [AllowNull()][object] $Value
    )
    $valueText = if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { '<none>' } else { [string]$Value }
    Write-Host ("|   - {0}: {1}" -f $Key, $valueText) -ForegroundColor DarkGray
}

function Write-LogStepResult {
    param(
        [Parameter(Mandatory=$true)][string] $Step,
        [Parameter(Mandatory=$true)][string] $Module,
        [Parameter(Mandatory=$true)][ValidateSet('OK','WARN','ERROR')][string] $Status,
        [Parameter(Mandatory=$true)][string] $Message,
        [double] $DurationSec = -1
    )

    $color = switch ($Status) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
    }

    $suffix = if ($DurationSec -ge 0) { " ({0:N2}s)" -f $DurationSec } else { '' }
    Write-Host ("| [{0}]   Step: {1,-10} Module: {2,-14} {3}{4}" -f $Status, $Step, $Module, $Message, $suffix) -ForegroundColor $color
    Write-Host ('+' + ('-' * 94) + '+') -ForegroundColor DarkCyan
}

<#
.SYNOPSIS
    Extracts structured diagnostic details from a PowerShell ErrorRecord.
#>
function Get-SetupErrorDetails {
    param(
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $inv = $ErrorRecord.InvocationInfo
    $scriptPath = if ($inv.ScriptName) { $inv.ScriptName } else { '<interactive>' }
    $line = if ($inv.ScriptLineNumber) { $inv.ScriptLineNumber } else { 0 }
    $col = if ($inv.OffsetInLine) { $inv.OffsetInLine } else { 0 }
    $cmd = if ($inv.MyCommand -and $inv.MyCommand.Name) { $inv.MyCommand.Name } else { '<unknown command>' }

    [pscustomobject]@{
        Message  = $ErrorRecord.Exception.Message
        Command  = $cmd
        Location = ('{0}:{1}:{2}' -f $scriptPath, $line, $col)
        ErrorId  = $ErrorRecord.FullyQualifiedErrorId
        Category = $ErrorRecord.CategoryInfo.Category
        Stack    = $ErrorRecord.ScriptStackTrace
    }
}

<#
.SYNOPSIS
    Writes an error banner, optionally pauses, then throws.
#>
<#
.SYNOPSIS
    Returns $true only when a human can actually answer a prompt.

.DESCRIPTION
    Used to keep error paths from blocking. Every caller of Exit-WithError in
    Toml/UV/Poetry omits -NonInteractive, so a missing pyproject.toml used to
    sit on "Press Enter to exit" forever in CI and in any scripted run.

    Set DEVSETUP_NONINTERACTIVE=1 to force the non-interactive answer.
#>
function Test-SetupInteractive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($env:DEVSETUP_NONINTERACTIVE -match '^(1|true|yes|on)$') { return $false }
    if ($env:CI -match '^(1|true|yes|on)$')             { return $false }
    if ($env:TF_BUILD -match '^(1|true|yes|on)$')       { return $false }   # Azure Pipelines
    if ($env:GITHUB_ACTIONS -match '^(1|true|yes|on)$') { return $false }

    try { if (-not [Environment]::UserInteractive) { return $false } } catch { }
    try { if ([Console]::IsInputRedirected)        { return $false } } catch { }

    return $true
}

function Exit-WithError {
    param(
        [Parameter(Mandatory=$true)][string] $Message,
        [bool] $NonInteractive = $false
    )
    $inv = $MyInvocation
    $scriptPath = if ($inv.ScriptName) { $inv.ScriptName } else { '<interactive>' }
    $line = if ($inv.ScriptLineNumber) { $inv.ScriptLineNumber } else { 0 }
    $col = if ($inv.OffsetInLine) { $inv.OffsetInLine } else { 0 }
    $cmd = if ($inv.MyCommand -and $inv.MyCommand.Name) { $inv.MyCommand.Name } else { 'Exit-WithError' }
    $fullMessage = "{0}`nAt: {1}:{2}:{3}`nFunction: {4}" -f $Message, $scriptPath, $line, $col, $cmd

    Write-Banner $fullMessage 'ERROR'
    # Prompt only when a human is actually there; an unattended run must fail
    # fast instead of blocking on Read-Host.
    if (-not $NonInteractive -and (Test-SetupInteractive)) {
        Read-Host "`nPress Enter to exit"
    }
    throw (New-Object System.Exception($fullMessage))
}