#Requires -Version 5.1
# =============================================================================
# Module  : Errors.psm1
# Purpose : Structured exception type and helpers for SetupCore.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

class SetupException : System.Exception {
    [string] $ErrorCode
    [string] $Step
    [hashtable] $Context

    SetupException([string] $message, [string] $errorCode, [string] $step, [hashtable] $context) : base($message) {
        $this.ErrorCode = if ($errorCode) { $errorCode } else { 'SETUP_ERROR' }
        $this.Step = if ($step) { $step } else { 'UNKNOWN' }
        $this.Context = if ($null -ne $context) { $context } else { @{} }
    }

    SetupException([string] $message, [string] $errorCode, [string] $step, [hashtable] $context, [System.Exception] $innerException) : base($message, $innerException) {
        $this.ErrorCode = if ($errorCode) { $errorCode } else { 'SETUP_ERROR' }
        $this.Step = if ($step) { $step } else { 'UNKNOWN' }
        $this.Context = if ($null -ne $context) { $context } else { @{} }
    }
}

function New-SetupException {
<#
.SYNOPSIS
    Creates a structured SetupException without throwing it.

.EXAMPLE
    throw (New-SetupException -Message 'Python not found' -ErrorCode 'PYTHON_NOT_FOUND' -Step '2/13')
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $ErrorCode,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Step,

        [Parameter()]
        [hashtable] $Context = @{},

        [Parameter()]
        [System.Exception] $InnerException
    )

    if ($InnerException) {
        return [SetupException]::new($Message, $ErrorCode, $Step, $Context, $InnerException)
    }

    return [SetupException]::new($Message, $ErrorCode, $Step, $Context)
}

function ConvertTo-SetupException {
<#
.SYNOPSIS
    Wraps an arbitrary PowerShell error in a SetupException.

.DESCRIPTION
    Existing SetupException instances are returned unchanged. Other exceptions
    receive the supplied error code, step and context while preserving the
    original exception as InnerException.

.EXAMPLE
    catch { throw (ConvertTo-SetupException -ErrorRecord $_ -ErrorCode 'PM_FAILED' -Step '9/13') }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $ErrorCode,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Step,

        [Parameter()]
        [hashtable] $Context = @{}
    )

    if ($ErrorRecord.Exception -is [SetupException]) {
        return $ErrorRecord.Exception
    }

    $message = if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
        $ErrorRecord.Exception.Message
    } else {
        [string]$ErrorRecord
    }

    New-SetupException `
        -Message $message `
        -ErrorCode $ErrorCode `
        -Step $Step `
        -Context $Context `
        -InnerException $ErrorRecord.Exception
}

Export-ModuleMember -Function New-SetupException, ConvertTo-SetupException
