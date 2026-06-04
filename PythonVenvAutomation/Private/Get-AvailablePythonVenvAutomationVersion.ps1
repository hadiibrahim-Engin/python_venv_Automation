function Get-AvailablePythonVenvAutomationVersion {
    <#
    .SYNOPSIS
        Queries the configured repository for the newest available version.

    .DESCRIPTION
        Prefers Microsoft.PowerShell.PSResourceGet (Find-PSResource) when present
        and falls back to PowerShellGet (Find-Module) on Windows PowerShell 5.1.
        The lookup runs inside a bounded job so a slow/unreachable feed cannot
        hang the terminal. Returns $null on timeout, error, or no result so the
        caller can apply offline/timeout policy.

    .PARAMETER ModuleName
        Module to look up.

    .PARAMETER RepositoryName
        Registered PowerShell repository to query.

    .PARAMETER AllowPrerelease
        When set, prerelease versions are considered.

    .PARAMETER TimeoutSeconds
        Maximum seconds to wait for the feed before giving up.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory)] [string] $ModuleName,
        [Parameter(Mandatory)] [string] $RepositoryName,
        [bool] $AllowPrerelease = $false,
        [int]  $TimeoutSeconds = 15
    )

    $finder = {
        param($ModuleName, $RepositoryName, $AllowPrerelease)

        $ErrorActionPreference = 'Stop'
        if (Get-Command -Name 'Find-PSResource' -ErrorAction SilentlyContinue) {
            $res = Find-PSResource -Name $ModuleName -Repository $RepositoryName -Prerelease:$AllowPrerelease -ErrorAction Stop |
                Sort-Object Version -Descending | Select-Object -First 1
            if ($res) { return [string]$res.Version }
        } elseif (Get-Command -Name 'Find-Module' -ErrorAction SilentlyContinue) {
            $params = @{ Name = $ModuleName; Repository = $RepositoryName; ErrorAction = 'Stop' }
            if ($AllowPrerelease) { $params['AllowPrerelease'] = $true }
            $res = Find-Module @params | Sort-Object Version -Descending | Select-Object -First 1
            if ($res) { return [string]$res.Version }
        } else {
            throw 'Neither Find-PSResource nor Find-Module is available to query the repository.'
        }
        return $null
    }

    try {
        $job = Start-Job -ScriptBlock $finder -ArgumentList $ModuleName, $RepositoryName, $AllowPrerelease
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            Write-Warning ("Repository version check exceeded {0}s timeout." -f $TimeoutSeconds)
            return $null
        }
        $raw = Receive-Job -Job $job -ErrorAction Stop
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warning ("Could not query repository '{0}': {1}" -f $RepositoryName, $_.Exception.Message)
        return $null
    }

    if ($raw) {
        # Strip any prerelease suffix (e.g. 1.2.0-preview1) before [version] parse.
        $stable = ([string]$raw -split '-', 2)[0]
        try { return [version]$stable } catch { return $null }
    }
    return $null
}
