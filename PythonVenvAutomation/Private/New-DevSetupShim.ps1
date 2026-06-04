function New-DevSetupShim {
    <#
    .SYNOPSIS
        Generates the <CommandName>.ps1 and <CommandName>.cmd shims plus the
        bootstrap helper into the target bin directory.

    .DESCRIPTION
        Reads the shim templates from the module's templates\ folder and replaces
        the __COMMAND_NAME__ placeholder with the configured command name. The
        generated file NAMES are derived from Get-DevSetupCommandName, so a rename
        in config\CommandName.ps1 changes both the file names and their content.

    .PARAMETER BinDirectory
        Destination directory for the shims. Defaults to Get-DevSetupBinDirectory.

    .PARAMETER CommandName
        Command name to bake in. Defaults to Get-DevSetupCommandName.

    .PARAMETER Force
        Overwrite existing shims.

    .OUTPUTS
        PSCustomObject with PsShimPath, CmdShimPath, BootstrapPath.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $BinDirectory,
        [string] $CommandName,
        [switch] $Force
    )

    if (-not $CommandName)  { $CommandName  = Get-DevSetupCommandName }
    if (-not $BinDirectory) { $BinDirectory = Get-DevSetupBinDirectory -Create }

    $moduleRoot = $Script:PythonVenvAutomationModuleRoot
    if (-not $moduleRoot) { $moduleRoot = Split-Path -Parent $PSScriptRoot }
    $templatesDir = Join-Path $moduleRoot 'templates'

    $psTemplate   = Join-Path $templatesDir 'CommandShim.ps1.template'
    $cmdTemplate  = Join-Path $templatesDir 'CommandShim.cmd.template'
    $bootTemplate = Join-Path $templatesDir 'DevSetup.Bootstrap.ps1'

    foreach ($t in @($psTemplate, $cmdTemplate, $bootTemplate)) {
        if (-not (Test-Path -LiteralPath $t -PathType Leaf)) {
            throw "Shim template not found: $t"
        }
    }

    if (-not (Test-Path -LiteralPath $BinDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $BinDirectory -Force | Out-Null
    }

    $psShimName  = "$CommandName.ps1"
    $cmdShimName = "$CommandName.cmd"
    $psShimPath   = Join-Path $BinDirectory $psShimName
    $cmdShimPath  = Join-Path $BinDirectory $cmdShimName
    $bootstrapPath = Join-Path $BinDirectory 'DevSetup.Bootstrap.ps1'

    foreach ($target in @($psShimPath, $cmdShimPath, $bootstrapPath)) {
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and -not $Force) {
            throw "$target already exists. Use -Force to overwrite."
        }
    }

    $psContent   = (Get-Content -LiteralPath $psTemplate  -Raw).Replace('__COMMAND_NAME__', $CommandName)
    $cmdContent  = (Get-Content -LiteralPath $cmdTemplate -Raw).Replace('__COMMAND_NAME__', $CommandName)
    $bootContent = (Get-Content -LiteralPath $bootTemplate -Raw)

    if ($PSCmdlet.ShouldProcess($BinDirectory, "Generate $psShimName / $cmdShimName / bootstrap")) {
        # .cmd must be ASCII / no BOM so cmd.exe parses it cleanly.
        Set-Content -LiteralPath $psShimPath   -Value $psContent   -Encoding UTF8
        [System.IO.File]::WriteAllText($cmdShimPath, $cmdContent, (New-Object System.Text.ASCIIEncoding))
        Set-Content -LiteralPath $bootstrapPath -Value $bootContent -Encoding UTF8
    }

    return [pscustomobject]@{
        PsShimPath    = $psShimPath
        CmdShimPath   = $cmdShimPath
        BootstrapPath = $bootstrapPath
        CommandName   = $CommandName
    }
}
