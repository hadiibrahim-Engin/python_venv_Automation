#Requires -Version 5.1
# =============================================================================
# Module  : Logging.psm1
# Purpose : Structured console/file logging with one correlation ID per run.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogCorrelationId = $null
$script:LogFilePath = $null
$script:LogLevel = 'INFO'

function Get-LogLevelRank {
    param([Parameter(Mandatory=$true)][string] $Level)
    switch ($Level.ToUpperInvariant()) {
        'DEBUG' { 10 }
        'INFO'  { 20 }
        'WARN'  { 30 }
        'ERROR' { 40 }
        default { 20 }
    }
}

function Start-StructuredLogSession {
<#
.SYNOPSIS
    Starts a logging session and assigns one correlation ID to the setup run.

.PARAMETER LogFilePath
    Newline-delimited JSON event file. Defaults to
    $env:TEMP\python-setup-log.json as required by the setup contract.

.EXAMPLE
    $id = Start-StructuredLogSession -LogLevel INFO
#>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('DEBUG','INFO','WARN','ERROR')]
        [string] $LogLevel = 'INFO',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $LogFilePath = $(Join-Path ([System.IO.Path]::GetTempPath()) 'python-setup-log.json')
    )

    $script:LogCorrelationId = [guid]::NewGuid().ToString()
    $script:LogLevel = $LogLevel.ToUpperInvariant()
    $script:LogFilePath = [System.IO.Path]::GetFullPath($LogFilePath)

    $parent = Split-Path -Parent $script:LogFilePath
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # Start each run with a clean event stream. The file is NDJSON: every line
    # is a standalone JSON object, which is stream-friendly for CI collectors.
    Set-Content -LiteralPath $script:LogFilePath -Value '' -Encoding UTF8 -ErrorAction Stop

    Write-StructuredLog -Level INFO -Step 'INIT' -Message 'Structured logging session started.' -NoConsole
    return $script:LogCorrelationId
}

function Get-StructuredLogContext {
<#
.SYNOPSIS
    Returns the current correlation ID, log level and log file path.
#>
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        CorrelationId = $script:LogCorrelationId
        LogLevel      = $script:LogLevel
        LogFilePath   = $script:LogFilePath
    }
}

function Write-StructuredLog {
<#
.SYNOPSIS
    Writes one structured log event to file and optionally to the console.

.DESCRIPTION
    The file format is newline-delimited JSON. Fields are stable for downstream
    ingestion: Timestamp, Level, Step, Message, CorrelationId, plus optional
    Module and Context.

.EXAMPLE
    Write-StructuredLog -Level INFO -Step PYTHON -Message 'Python selected.'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('DEBUG','INFO','WARN','ERROR')]
        [string] $Level,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Step,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        [Parameter()]
        [string] $Module,

        [Parameter()]
        [hashtable] $Context = @{},

        [Parameter()]
        [switch] $NoConsole
    )

    $normalizedLevel = $Level.ToUpperInvariant()
    if ((Get-LogLevelRank -Level $normalizedLevel) -lt (Get-LogLevelRank -Level $script:LogLevel)) {
        return
    }

    if (-not $script:LogCorrelationId) {
        $script:LogCorrelationId = [guid]::NewGuid().ToString()
    }
    if (-not $script:LogFilePath) {
        $script:LogFilePath = Join-Path ([System.IO.Path]::GetTempPath()) 'python-setup-log.json'
    }

    $record = [ordered]@{
        Timestamp     = [DateTime]::UtcNow.ToString('o')
        Level         = $normalizedLevel
        Step          = $Step
        Message       = $Message
        CorrelationId = $script:LogCorrelationId
    }
    if ($Module) { $record.Module = $Module }
    if ($Context -and $Context.Count -gt 0) { $record.Context = $Context }

    $json = $record | ConvertTo-Json -Depth 8 -Compress
    Add-Content -LiteralPath $script:LogFilePath -Value $json -Encoding UTF8 -ErrorAction Stop

    if (-not $NoConsole) {
        $color = switch ($normalizedLevel) {
            'ERROR' { 'Red' }
            'WARN'  { 'Yellow' }
            'DEBUG' { 'DarkGray' }
            default { 'Cyan' }
        }
        Write-Host ("[{0}] [{1}] {2}" -f $normalizedLevel, $Step, $Message) -ForegroundColor $color
    }
}

Export-ModuleMember -Function Start-StructuredLogSession, Get-StructuredLogContext, Write-StructuredLog
