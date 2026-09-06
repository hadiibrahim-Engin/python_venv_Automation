#Requires -Version 5.1
# =============================================================================
# Module  : Versioning.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Errors.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop

<#
.SYNOPSIS
    Version constraint parsing and evaluation helpers.

.DESCRIPTION
    Parsing is FAIL-CLOSED. A Python requirement that cannot be fully and
    unambiguously interpreted raises PYTHON_CONSTRAINT_UNSUPPORTED rather than
    being partially applied. Silently dropping a token we do not understand
    would weaken the project's Python requirement, which is worse than
    refusing to proceed.
#>

<#
.SYNOPSIS
    Raises a structured, fail-closed constraint error.
#>
function New-ConstraintError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $ConstraintStr,
        [Parameter(Mandatory=$true)][string] $Token,
        [Parameter(Mandatory=$true)][string] $Detail
    )
    return (New-SetupException `
        -Message ("Unsupported Python version constraint '{0}' (in '{1}'): {2}" -f $Token, $ConstraintStr, $Detail) `
        -ErrorCode 'PYTHON_CONSTRAINT_UNSUPPORTED' `
        -Step 'METADATA' `
        -Context @{ ConstraintStr = $ConstraintStr; Token = $Token; Detail = $Detail })
}

<#
.SYNOPSIS
    Converts a Python version-constraint string to structured rules.

.DESCRIPTION
    Supported syntax:
        >=X.Y  <=X.Y  >X.Y  <X.Y      standard comparisons
        ==X.Y                          the X.Y line  (>=X.Y, <X.(Y+1))
        ==X.Y.Z                        that exact release
        ==X.Y.*                        the X.Y line
        !=X.Y                          excludes the whole X.Y line
        !=X.Y.Z                        excludes that exact release
        ^X.Y                           Poetry caret  (>=X.Y, <(X+1).0)
        ~X.Y                           Poetry tilde  (>=X.Y, <X.(Y+1))
        ~=X.Y / ~=X.Y.Z                PEP 440 compatible release
        X.Y                            bare version, treated as ==X.Y

    Anything else throws PYTHON_CONSTRAINT_UNSUPPORTED.

.OUTPUTS
    List[hashtable] with Op and Version keys. Op is one of
    '>=', '<=', '>', '<', '==', '!=', '!=line'.
#>
function ConvertTo-VersionConstraints {
    param([Parameter(Mandatory=$true)][string] $ConstraintStr)

    if ([string]::IsNullOrWhiteSpace($ConstraintStr)) {
        throw (New-ConstraintError -ConstraintStr $ConstraintStr -Token '<empty>' `
            -Detail 'the Python requirement is empty')
    }

    $result = [System.Collections.Generic.List[hashtable]]::new()

    # --- Pass 1: expand Poetry/PEP 440 shorthand into plain comparisons -----
    $expanded = [System.Collections.Generic.List[string]]::new()
    foreach ($rawPart in ($ConstraintStr -split ',')) {
        $part = $rawPart.Trim()
        if ([string]::IsNullOrWhiteSpace($part)) {
            throw (New-ConstraintError -ConstraintStr $ConstraintStr -Token '<empty segment>' `
                -Detail 'empty constraint segment (stray comma)')
        }

        if ($part -match '^\^(\d+)\.(\d+)(?:\.(\d+))?$') {
            # ^X.Y  => >=X.Y, <(X+1).0     ^0.Y => >=0.Y, <0.(Y+1)
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            if ($major -gt 0) {
                $expanded.Add(">=$major.$minor")
                $expanded.Add("<$($major + 1).0")
            } else {
                $expanded.Add(">=$major.$minor")
                $expanded.Add("<$major.$($minor + 1)")
            }
        }
        elseif ($part -match '^~(\d+)\.(\d+)(?:\.(\d+))?$') {
            # ~X.Y => >=X.Y, <X.(Y+1)
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            $expanded.Add(">=$major.$minor")
            $expanded.Add("<$major.$($minor + 1)")
        }
        elseif ($part -match '^~=(\d+(?:\.\d+)*)$') {
            # PEP 440 compatible release. Requires at least two components:
            # drop the rightmost, increment the new rightmost.
            $components = $Matches[1] -split '\.'
            if ($components.Length -lt 2) {
                throw (New-ConstraintError -ConstraintStr $ConstraintStr -Token $part `
                    -Detail '~= requires at least two version components (e.g. ~=3.11)')
            }
            $lower = $Matches[1]
            $upperParts = [string[]]$components[0..($components.Length - 2)]
            $upperParts[-1] = [string]([int]$upperParts[-1] + 1)
            # ~=3.11 caps at 4.0, not "4": every bound must be major.minor.
            if ($upperParts.Length -eq 1) { $upperParts += '0' }
            $expanded.Add(">=$lower")
            $expanded.Add("<$($upperParts -join '.')")
        }
        elseif ($part -match '^(==|!=)\s*(\d+)\.(\d+)\.\*$') {
            # ==X.Y.*  /  !=X.Y.*  -> the whole X.Y line
            $op    = $Matches[1]
            $major = [int]$Matches[2]
            $minor = [int]$Matches[3]
            if ($op -eq '==') {
                $expanded.Add(">=$major.$minor")
                $expanded.Add("<$major.$($minor + 1)")
            } else {
                $expanded.Add("!=$major.$minor")
            }
        }
        else {
            $expanded.Add($part)
        }
    }

    # --- Pass 2: parse plain comparisons; refuse anything unrecognised -----
    foreach ($part in $expanded) {
        $token = $part.Trim()

        # Bare version ("3.11") is treated as an equality constraint.
        if ($token -match '^\d+(?:\.\d+)*$') { $token = "==$token" }

        if ($token -notmatch '^(>=|<=|>|<|==|!=)\s*(\d+(?:\.\d+)*)$') {
            throw (New-ConstraintError -ConstraintStr $ConstraintStr -Token $part `
                -Detail 'not a recognised version comparison')
        }

        $op          = $Matches[1]
        $versionText = $Matches[2]
        $componentCount = ($versionText -split '\.').Count

        if ($componentCount -lt 2) {
            throw (New-ConstraintError -ConstraintStr $ConstraintStr -Token $part `
                -Detail 'a version needs at least major.minor (e.g. 3.11)')
        }

        try {
            $version = [Version]$versionText
        } catch {
            throw (New-ConstraintError -ConstraintStr $ConstraintStr -Token $part `
                -Detail ("'{0}' is not a valid version number" -f $versionText))
        }

        if ($op -eq '==' -and $componentCount -eq 2) {
            # For interpreter selection "==3.11" means the 3.11 line, not the
            # non-existent exact release 3.11.0, so installed patches like
            # 3.11.9 keep matching on later runs.
            $result.Add(@{ Op = '>='; Version = $version })
            $result.Add(@{ Op = '<';  Version = [Version]("{0}.{1}" -f $version.Major, ($version.Minor + 1)) })
        }
        elseif ($op -eq '!=' -and $componentCount -eq 2) {
            # "!=3.12" must exclude every 3.12.x, not just the literal 3.12.0.
            $result.Add(@{ Op = '!=line'; Version = $version })
        }
        else {
            $result.Add(@{ Op = $op; Version = $version })
        }
    }

    if ($result.Count -eq 0) {
        throw (New-ConstraintError -ConstraintStr $ConstraintStr -Token $ConstraintStr `
            -Detail 'no usable constraint could be derived')
    }

    ,$result
}

<#
.SYNOPSIS
    Evaluates whether a version satisfies all parsed constraints.

.DESCRIPTION
    An unknown operator is a hard error, not a silent pass: accepting it would
    let an unparsed requirement through as "satisfied".
#>
function Test-VersionConstraints {
    param(
        [Parameter(Mandatory=$true)][Version] $Version,
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[hashtable]] $Constraints
    )
    foreach ($c in $Constraints) {
        $ok = switch ($c.Op) {
            '>='     { $Version -ge $c.Version }
            '<='     { $Version -le $c.Version }
            '>'      { $Version -gt $c.Version }
            '<'      { $Version -lt $c.Version }
            '=='     { $Version -eq $c.Version }
            '!='     { $Version -ne $c.Version }
            '!=line' { -not ($Version.Major -eq $c.Version.Major -and $Version.Minor -eq $c.Version.Minor) }
            default  {
                throw (New-SetupException `
                    -Message ("Unknown version-constraint operator '{0}'." -f $c.Op) `
                    -ErrorCode 'PYTHON_CONSTRAINT_UNSUPPORTED' -Step 'METADATA' `
                    -Context @{ Op = $c.Op })
            }
        }
        if (-not $ok) { return $false }
    }
    $true
}

Export-ModuleMember -Function ConvertTo-VersionConstraints, Test-VersionConstraints
