#Requires -Version 5.1
# =============================================================================
# Module  : SupportCodes.psm1
# Purpose : Stable, user-facing support codes (Part V).
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
    End users never see a PowerShell exception. They see a short German
    sentence and a stable code (DS-xxnnn) that support can look up. The full
    technical context stays in the structured log.

    Ranges:
        DS-U1xx  update / installation
        DS-P2xx  project configuration (pyproject, package manager, lock)
        DS-V3xx  virtual environment and Python
        DS-S4xx  signing
        DS-G5xx  git
        DS-X9xx  unclassified
#>

$script:SupportCodeMap = @{
    # --- Update / installation -------------------------------------------
    'DS-U101' = @{ Title = 'DevSetup konnte nicht aktualisiert werden.';       Detail = 'Die Verbindung zu Azure DevOps ist fehlgeschlagen. Es wird mit der lokal installierten Version weitergearbeitet.' }
    'DS-U102' = @{ Title = 'DevSetup ist zu alt.';                             Detail = 'Die installierte Version wird nicht mehr unterstuetzt und es ist keine Verbindung zur Aktualisierung moeglich.' }
    'DS-U103' = @{ Title = 'Das Update-Paket ist beschaedigt.';                Detail = 'Die Pruefsumme oder Signatur des heruntergeladenen Pakets stimmt nicht. Es wurde nichts installiert.' }
    'DS-U104' = @{ Title = 'Eine neue DevSetup-Version konnte nicht gestartet werden.'; Detail = 'Die vorherige funktionierende Version wurde automatisch wiederhergestellt. Sie koennen weiterarbeiten.' }
    'DS-U105' = @{ Title = 'Ein anderes Fenster aktualisiert DevSetup gerade.'; Detail = 'Bitte warten Sie einen Moment und starten Sie den Befehl erneut.' }

    # --- Project configuration -------------------------------------------
    'DS-P201' = @{ Title = 'Die Projektkonfiguration konnte nicht gelesen werden.'; Detail = 'pyproject.toml fehlt, ist leer oder enthaelt einen Syntaxfehler.' }
    'DS-P202' = @{ Title = 'Die Python-Anforderung des Projekts ist ungueltig.';    Detail = 'Der Eintrag requires-python kann nicht eindeutig ausgewertet werden.' }
    'DS-P203' = @{ Title = 'Die Projektkonfiguration ist unvollstaendig.';          Detail = 'Pflichtangaben wie Name oder Python-Anforderung fehlen.' }
    'DS-P204' = @{ Title = 'Ein Konfigurationskonflikt benoetigt eine fachliche Entscheidung.'; Detail = 'Es ist nicht eindeutig, ob das Projekt mit uv oder mit Poetry verwaltet wird.' }
    'DS-P205' = @{ Title = 'Die Abhaengigkeitsdatei passt nicht zum Projekt.';      Detail = 'Die vorhandene Lock-Datei gehoert zu einem anderen Paketmanager oder ist beschaedigt.' }
    'DS-P206' = @{ Title = 'Die Projektkonfiguration konnte nicht repariert werden.'; Detail = 'Die Aenderung wurde vollstaendig zurueckgenommen. Die Datei ist unveraendert.' }

    # --- Virtual environment / Python ------------------------------------
    'DS-V301' = @{ Title = 'Es wurde keine passende Python-Version gefunden.';   Detail = 'Auf diesem Rechner ist keine Python-Installation vorhanden, die zur Anforderung des Projekts passt.' }
    'DS-V302' = @{ Title = 'Die Arbeitsumgebung konnte nicht erstellt werden.';  Detail = 'Das Verzeichnis .venv konnte nicht angelegt oder nicht validiert werden.' }
    'DS-V303' = @{ Title = 'Die Abhaengigkeiten konnten nicht installiert werden.'; Detail = 'Der Paketmanager hat die Installation mit einem Fehler beendet.' }
    'DS-V304' = @{ Title = 'Die Arbeitsumgebung wird von einem anderen Programm benutzt.'; Detail = 'Bitte schliessen Sie offene Editoren oder Terminals und versuchen Sie es erneut.' }

    # --- Signing ----------------------------------------------------------
    'DS-S401' = @{ Title = 'Die Signaturpruefung ist fehlgeschlagen.';          Detail = 'Mindestens eine Datei konnte nicht signiert oder nicht geprueft werden.' }
    'DS-S402' = @{ Title = 'Das Signaturwerkzeug wurde nicht gefunden.';        Detail = 'Das DigiCert-Dienstprogramm ist auf diesem Rechner nicht installiert.' }

    # --- Git --------------------------------------------------------------
    'DS-G501' = @{ Title = 'Das Repository konnte nicht aktualisiert werden.';  Detail = 'Es liegen lokale Aenderungen vor oder der Stand weicht vom Server ab. Es wurde nichts veraendert.' }
    'DS-G502' = @{ Title = 'Git ist nicht verfuegbar.';                         Detail = 'Git wurde auf diesem Rechner nicht gefunden.' }

    # --- Fallback ---------------------------------------------------------
    'DS-X901' = @{ Title = 'DevSetup konnte das Projekt nicht vollstaendig vorbereiten.'; Detail = 'Es ist ein unerwarteter Fehler aufgetreten.' }
}

# Maps internal ErrorCodes onto user-facing support codes.
$script:ErrorCodeToSupportCode = @{
    'PLATFORM_UNSUPPORTED'                = 'DS-X901'
    'PYPROJECT_PARSE_INVALID'             = 'DS-P201'
    'TOML_PARSE_ERROR'                    = 'DS-P201'
    'TOML_FILE_NOT_FOUND'                 = 'DS-P201'
    'PROJECT_METADATA_FAILED'             = 'DS-P201'
    'PYPROJECT_MISSING'                   = 'DS-P201'
    'PYPROJECT_EMPTY'                     = 'DS-P201'
    'CONFIG_INVALID'                      = 'DS-P201'
    'PYTHON_CONSTRAINT_UNSUPPORTED'       = 'DS-P202'
    'PYPROJECT_PYTHON_CONSTRAINT_INVALID' = 'DS-P202'
    'PYPROJECT_PYTHON_CONSTRAINT_CONFLICT'= 'DS-P202'
    'PYPROJECT_NAME_MISSING'              = 'DS-P203'
    'PYPROJECT_REQUIRES_PYTHON_MISSING'   = 'DS-P203'
    'PYPROJECT_PM_AMBIGUOUS'              = 'DS-P204'
    'PYPROJECT_MULTIPLE_LOCKFILES'        = 'DS-P204'
    'PYPROJECT_METADATA_DIVERGED'         = 'DS-P204'
    'LOCK_WRONG_MANAGER'                  = 'DS-P205'
    'LOCK_INVALID'                        = 'DS-P205'
    'PYPROJECT_HEAL_FAILED'               = 'DS-P206'
    'PYTHON_RESOLUTION_FAILED'            = 'DS-V301'
    'PYTHON_NOT_FOUND'                    = 'DS-V301'
    'VENV_INVALID'                        = 'DS-V302'
    'VENV_PYTHON_MISSING'                 = 'DS-V302'
    'DEPENDENCY_INSTALL_FAILED'           = 'DS-V303'
    'SIGNING_FAILED'                      = 'DS-S401'
    'DIGICERT_NOT_FOUND'                  = 'DS-S402'
    'GIT_SYNC_FAILED'                     = 'DS-G501'
    'GIT_NOT_FOUND'                       = 'DS-G502'
}

function Get-DevSetupSupportCode {
<#
.SYNOPSIS
    Maps an internal ErrorCode onto a stable user-facing support code.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string] $ErrorCode)

    if ([string]::IsNullOrWhiteSpace($ErrorCode)) { return 'DS-X901' }
    if ($script:ErrorCodeToSupportCode.ContainsKey($ErrorCode)) { return $script:ErrorCodeToSupportCode[$ErrorCode] }
    return 'DS-X901'
}

function Get-DevSetupSupportCodeTable {
<#
.SYNOPSIS
    Returns every known support code with its user-facing text.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    $rows = foreach ($code in ($script:SupportCodeMap.Keys | Sort-Object)) {
        [pscustomobject]@{
            Code   = $code
            Title  = $script:SupportCodeMap[$code].Title
            Detail = $script:SupportCodeMap[$code].Detail
        }
    }
    return $rows
}

function Format-DevSetupUserError {
<#
.SYNOPSIS
    Renders the message an end user is allowed to see.

.DESCRIPTION
    Never contains a stack trace, a module name or a PowerShell type. The
    technical detail belongs in the structured log; here we print a plain
    sentence, the support code, and the one command that helps.

.PARAMETER CommandName
    The user-facing command name, so the hint says `devsetup support` (or
    whatever the shim is called).
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string] $ErrorCode,
        [Parameter()][AllowNull()][AllowEmptyString()][string] $ExtraHint,
        [Parameter()][string] $CommandName = 'devsetup'
    )

    $support = Get-DevSetupSupportCode -ErrorCode $ErrorCode
    $entry = $script:SupportCodeMap[$support]

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('')
    $lines.Add($entry.Title)
    $lines.Add('')
    $lines.Add($entry.Detail)
    if (-not [string]::IsNullOrWhiteSpace($ExtraHint)) {
        $lines.Add('')
        $lines.Add($ExtraHint)
    }
    $lines.Add('')
    $lines.Add(('Fehlercode: {0}' -f $support))
    $lines.Add('')
    $lines.Add('Bitte fuehren Sie bei Bedarf aus:')
    $lines.Add('')
    $lines.Add(('    {0} support' -f $CommandName))
    $lines.Add('')
    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function Get-DevSetupSupportCode, Get-DevSetupSupportCodeTable, Format-DevSetupUserError
