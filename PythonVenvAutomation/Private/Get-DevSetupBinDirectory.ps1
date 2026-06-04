function Get-DevSetupBinDirectory {
    <#
    .SYNOPSIS
        Returns the user-local bin directory that holds the generated shims.

    .DESCRIPTION
        Resolves to %LOCALAPPDATA%\Company\PythonVenvAutomation\bin. The shims,
        the bootstrap helper, and (one level up) the runtime config and update
        lock all live under this user-local, no-admin-required tree.

        Cross-platform note: on non-Windows hosts (used only for unit testing)
        LOCALAPPDATA is empty, so the .NET LocalApplicationData folder is used
        as a fallback. The directory is created on demand.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch] $Create
    )

    $bin = Join-Path (Get-DevSetupRootDirectory) 'bin'
    if ($Create -and -not (Test-Path -LiteralPath $bin -PathType Container)) {
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
    }
    return $bin
}

function Get-DevSetupRootDirectory {
    <#
    .SYNOPSIS
        Returns %LOCALAPPDATA%\Company\PythonVenvAutomation (created on demand
        by callers that need it). 'Company' is the vendor folder placeholder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [System.Environment]::GetFolderPath('LocalApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        # Last-resort fallback so tooling never crashes on an exotic host.
        $localAppData = Join-Path ([System.IO.Path]::GetTempPath()) 'LocalAppData'
    }
    return (Join-Path (Join-Path $localAppData 'Company') 'PythonVenvAutomation')
}
