#Requires -Version 5.1
# =============================================================================
# Module  : Versioning.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Version constraint parsing and evaluation helpers.
#>

<#
.SYNOPSIS
    Converts a Python version-constraint string to structured rules.

.DESCRIPTION
    Parses comparison operators and expands caret/tilde shorthand into
    explicit lower/upper bounds for consistent version filtering.
#>
function ConvertTo-VersionConstraints {
    param([Parameter(Mandatory=$true)][string] $ConstraintStr)
    $result = [System.Collections.Generic.List[hashtable]]::new()

    # Expand Poetry-style caret (^) and tilde (~) before standard operator parsing.
    # ^X.Y  => >=X.Y, <(X+1).0   e.g. ^3.11 => >=3.11, <4.0
    # ^0.Y  => >=0.Y, <0.(Y+1)   (semver minor-range when major is 0)
    # ~X.Y  => >=X.Y, <X.(Y+1)   e.g. ~3.11 => >=3.11, <3.12
    $expanded = [System.Collections.Generic.List[string]]::new()
    foreach ($part in ($ConstraintStr -split ',')) {
        $part = $part.Trim()
        if ($part -match '^\^(\d+)\.(\d+)(?:\.(\d+))?$') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            if ($major -gt 0) {
                $expanded.Add(">=$major.$minor")
                $expanded.Add("<$([int]$major + 1).0")
            } else {
                $expanded.Add(">=$major.$minor")
                $expanded.Add("<$major.$([int]$minor + 1)")
            }
        } elseif ($part -match '^~(\d+)\.(\d+)(?:\.(\d+))?$') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            $expanded.Add(">=$major.$minor")
            $expanded.Add("<$major.$([int]$minor + 1)")
        } elseif ($part -match '^~=(\d+(?:\.\d+)+)$') {
            # PEP 440 compatible release: ~=X.Y means >=X.Y, <(X+1).0
            #                             ~=X.Y.Z means >=X.Y.Z, <X.(Y+1).0
            # Rule: drop the rightmost component, increment the new rightmost.
            $components = $Matches[1] -split '\.'
            if ($components.Length -ge 2) {
                $lower = $Matches[1]
                $upperParts = [string[]]$components[0..($components.Length - 2)]
                $upperParts[-1] = [string]([int]$upperParts[-1] + 1)
                $expanded.Add(">=$lower")
                $expanded.Add("<$($upperParts -join '.')")
            }
        } else {
            $expanded.Add($part)
        }
    }

    foreach ($part in $expanded) {
        $part = $part.Trim()
        # Allow bare versions (for example "3.11") by treating them as equality constraints.
        if ($part -match '^\d+(?:\.\d+)*$') {
            $part = "==$part"
        }
        if ($part -match '^(>=|<=|>|<|==|!=)\s*(\d+(?:\.\d+)*)') {
            try {
                $result.Add(@{ Op = $Matches[1]; Version = [Version]$Matches[2] })
            } catch {
                Write-Host ("Warning: could not parse version token '{0}' -- skipping." -f $part) -ForegroundColor DarkYellow
            }
        }
    }
    ,$result
}

<#
.SYNOPSIS
    Evaluates whether a version satisfies all parsed constraints.
#>
function Test-VersionConstraints {
    param(
        [Parameter(Mandatory=$true)][Version] $Version,
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[hashtable]] $Constraints
    )
    foreach ($c in $Constraints) {
        $ok = switch ($c.Op) {
            '>='    { $Version -ge $c.Version }
            '<='    { $Version -le $c.Version }
            '>'     { $Version -gt $c.Version }
            '<'     { $Version -lt $c.Version }
            '=='    { $Version -eq $c.Version }
            '!='    { $Version -ne $c.Version }
            default { $true }
        }
        if (-not $ok) { return $false }
    }
    $true
}

Export-ModuleMember -Function ConvertTo-VersionConstraints, Test-VersionConstraints