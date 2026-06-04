function Test-PythonVenvAutomationVersion {
    <#
    .SYNOPSIS
        Decides what update action (if any) is required for the given policy.

    .DESCRIPTION
        Pure decision function (no side effects) so it is easy to unit-test with
        mocked version inputs. Returns a decision object:

            Action  : 'none' | 'install' | 'update' | 'fail'
            Target  : [version] to install/update to, or $null
            Reason  : human-readable explanation

        Supported policies: LatestStable, MinimumRequired, Pinned, Disabled.

    .PARAMETER Policy
        Auto-update policy.

    .PARAMETER Installed
        Newest locally-installed [version], or $null when nothing is installed.

    .PARAMETER Available
        Newest available [version] from the repository, or $null when the feed
        could not be reached (offline / timeout).

    .PARAMETER RequiredVersion
        Target [version] for MinimumRequired / Pinned policies.

    .PARAMETER PinnedInstalled
        For Pinned policy: whether the exact RequiredVersion is already installed.

    .PARAMETER AllowOfflineContinue
        Whether to continue with the installed version when the feed is offline
        and the installed version is otherwise acceptable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('LatestStable', 'MinimumRequired', 'Pinned', 'Disabled')]
        [string]  $Policy,

        [version] $Installed,
        [version] $Available,
        [version] $RequiredVersion,
        [bool]    $PinnedInstalled = $false,
        [bool]    $AllowOfflineContinue = $true
    )

    function New-Decision { param($Action, $Target, $Reason) @{ Action = $Action; Target = $Target; Reason = $Reason } }

    switch ($Policy) {
        'Disabled' {
            return New-Decision 'none' $null 'Auto-update is disabled by policy.'
        }

        'Pinned' {
            if (-not $RequiredVersion) {
                return New-Decision 'fail' $null 'Pinned policy requires RequiredVersion to be set.'
            }
            if ($PinnedInstalled) {
                return New-Decision 'none' $RequiredVersion ("Pinned version {0} already installed." -f $RequiredVersion)
            }
            # Exact version missing -> must install it (from feed when reachable).
            if ($null -eq $Available -and -not $AllowOfflineContinue) {
                return New-Decision 'fail' $RequiredVersion ("Pinned version {0} is missing and the repository is unreachable." -f $RequiredVersion)
            }
            if ($null -eq $Available) {
                return New-Decision 'fail' $RequiredVersion ("Pinned version {0} is missing and the repository is unreachable." -f $RequiredVersion)
            }
            return New-Decision 'install' $RequiredVersion ("Installing pinned version {0}." -f $RequiredVersion)
        }

        'MinimumRequired' {
            if (-not $RequiredVersion) {
                return New-Decision 'fail' $null 'MinimumRequired policy requires RequiredVersion to be set.'
            }
            if ($null -eq $Installed) {
                if ($null -eq $Available -and -not $AllowOfflineContinue) {
                    return New-Decision 'fail' $RequiredVersion 'No module installed and repository unreachable.'
                }
                if ($null -eq $Available) {
                    return New-Decision 'fail' $RequiredVersion 'No module installed and repository unreachable.'
                }
                return New-Decision 'install' $RequiredVersion ("Installing required minimum version {0}." -f $RequiredVersion)
            }
            if ($Installed -lt $RequiredVersion) {
                if ($null -eq $Available) {
                    return New-Decision 'fail' $RequiredVersion ("Installed {0} is below required {1} and the repository is unreachable." -f $Installed, $RequiredVersion)
                }
                return New-Decision 'update' $RequiredVersion ("Updating {0} -> at least {1}." -f $Installed, $RequiredVersion)
            }
            return New-Decision 'none' $Installed ("Installed {0} satisfies required minimum {1}." -f $Installed, $RequiredVersion)
        }

        default {
            # LatestStable
            if ($null -eq $Installed) {
                if ($null -eq $Available -and -not $AllowOfflineContinue) {
                    return New-Decision 'fail' $null 'No module installed and repository unreachable.'
                }
                if ($null -eq $Available) {
                    return New-Decision 'fail' $null 'No module installed and repository unreachable.'
                }
                return New-Decision 'install' $Available ("Installing latest stable version {0}." -f $Available)
            }
            if ($null -eq $Available) {
                if ($AllowOfflineContinue) {
                    return New-Decision 'none' $Installed ("Could not check for updates. Continuing with installed {0}." -f $Installed)
                }
                return New-Decision 'fail' $null 'Repository unreachable and offline continue is disabled.'
            }
            if ($Available -gt $Installed) {
                return New-Decision 'update' $Available ("Newer version available: {0} -> {1}." -f $Installed, $Available)
            }
            return New-Decision 'none' $Installed ("Installed {0} is current." -f $Installed)
        }
    }
}
