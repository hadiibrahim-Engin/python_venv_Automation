#Requires -Version 5.1
# =============================================================================
# Module  : SetupPipeline.psm1
# Purpose : Reusable pipeline-step primitives for Start-Setup decomposition.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Errors.psm1') -Force -DisableNameChecking -ErrorAction Stop

function New-SetupPipelineStep {
<#
.SYNOPSIS
    Creates one setup pipeline step definition.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $Name,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $Module,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $Message,
        [Parameter(Mandatory=$true)][ValidateNotNull()][scriptblock] $Action,
        [Parameter()][bool] $Mandatory = $true,
        [Parameter()][switch] $ReadOnly,
        [Parameter()][ValidateNotNullOrEmpty()][string] $ErrorCode = 'SETUP_STEP_FAILED'
    )

    [pscustomobject]@{
        PSTypeName = 'PythonVenvAutomation.SetupPipelineStep'
        Name = $Name
        Module = $Module
        Message = $Message
        Action = $Action
        Mandatory = [bool]$Mandatory
        ReadOnly = [bool]$ReadOnly
        ErrorCode = $ErrorCode
    }
}

function Invoke-SetupPipelineStep {
<#
.SYNOPSIS
    Executes one setup pipeline step with timing and normalized error handling.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateNotNull()][psobject] $Step,
        [Parameter()][switch] $DryRun,
        [Parameter()][scriptblock] $OnStart,
        [Parameter()][scriptblock] $OnResult,
        [Parameter()][scriptblock] $OnDetail
    )

    foreach ($required in @('Name','Module','Message','Action','Mandatory','ReadOnly','ErrorCode')) {
        if ($Step.PSObject.Properties.Name -notcontains $required) {
            throw (New-SetupException -Message "Invalid pipeline step: missing property '$required'." -ErrorCode 'PIPELINE_STEP_INVALID' -Step 'PIPELINE' -Context @{ MissingProperty=$required })
        }
    }

    if ($OnStart) { & $OnStart $Step }

    if ($DryRun -and -not [bool]$Step.ReadOnly) {
        if ($OnResult) { & $OnResult $Step 'SKIPPED' 'Dry-run: mutating step skipped.' 0.0 }
        return [pscustomobject]@{ Step=$Step.Name; Status='SKIPPED'; DurationSec=0.0; Result=$null }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Step.Action
        $sw.Stop()
        if ($OnResult) { & $OnResult $Step 'OK' $Step.Message $sw.Elapsed.TotalSeconds }
        return [pscustomobject]@{ Step=$Step.Name; Status='OK'; DurationSec=$sw.Elapsed.TotalSeconds; Result=$result }
    }
    catch {
        $sw.Stop()
        $setupError = ConvertTo-SetupException -ErrorRecord $_ -ErrorCode ([string]$Step.ErrorCode) -Step ([string]$Step.Name) -Context @{ Module=[string]$Step.Module; Message=[string]$Step.Message }
        $status = if ([bool]$Step.Mandatory) { 'ERROR' } else { 'WARN' }
        if ($OnResult) { & $OnResult $Step $status $setupError.Message $sw.Elapsed.TotalSeconds }
        if ($OnDetail) { & $OnDetail 'error_code' $setupError.ErrorCode; & $OnDetail 'step' $setupError.Step }
        if ([bool]$Step.Mandatory) { throw $setupError }
        return [pscustomobject]@{ Step=$Step.Name; Status='WARN'; DurationSec=$sw.Elapsed.TotalSeconds; Result=$null; Error=$setupError }
    }
}

function Invoke-SetupPipeline {
<#
.SYNOPSIS
    Executes an ordered collection of setup pipeline step definitions.

.EXAMPLE
    Invoke-SetupPipeline -Steps $steps -DryRun:$false
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateNotNull()][object[]] $Steps,
        [Parameter()][switch] $DryRun,
        [Parameter()][scriptblock] $OnStart,
        [Parameter()][scriptblock] $OnResult,
        [Parameter()][scriptblock] $OnDetail
    )

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($step in $Steps) {
        $result = Invoke-SetupPipelineStep -Step $step -DryRun:$DryRun -OnStart $OnStart -OnResult $OnResult -OnDetail $OnDetail
        [void]$results.Add($result)
    }

    # Windows PowerShell 5.1 can throw an ArgumentException when an array
    # subexpression is applied directly to a generic List[object]. Copy the
    # elements explicitly into a normal PowerShell object array instead.
    return [object[]]$results.ToArray()
}

Export-ModuleMember -Function New-SetupPipelineStep, Invoke-SetupPipelineStep, Invoke-SetupPipeline
