function Write-DevSetupHelp {
    <#
    .SYNOPSIS
        Returns the command help text, rendered with the configured command name.

    .DESCRIPTION
        The help is built dynamically from Get-DevSetupCommandName so renaming the
        command (config\CommandName.ps1) automatically updates every line here.
        Returns the text as a single string; callers (the shim, help command) write
        it to the host. -AsString is the default; use -Emit to Write-Host directly.

    .PARAMETER CommandName
        Override the command name (used by tests). Defaults to Get-DevSetupCommandName.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $CommandName,
        [switch] $Emit
    )

    if (-not $CommandName) { $CommandName = Get-DevSetupCommandName }
    $c = $CommandName

    $lines = @(
        "$c - Python project environment setup automation"
        ''
        'Usage:'
        "  $c"
        "  $c update"
        "  $c upgrade"
        "  $c rebuild"
        "  $c dry"
        "  $c prod"
        "  $c list-python"
        "  $c self-update"
        "  $c help"
        ''
        'Advanced:'
        "  $c -- -PackageManager uv -NonInteractive"
        "  $c update -- -UpgradePackage requests"
        "  $c dry -- -PackageManager poetry"
        ''
        'Self-update:'
        "  $c self-update        Update the automation module and command shims now."
        "  $c --no-self-update   Skip update check for this run."
        "  $c --force-self-update"
        '                              Force update check before running.'
        ''
        'Commands:'
        "  setup        Run full setup. Same as $c."
        '  update       Refresh existing .venv without reinstalling tools.'
        '  upgrade      Refresh existing .venv and intentionally upgrade dependencies.'
        '  rebuild      Remove and recreate .venv.'
        '  dry          Print the planned setup without modifying files.'
        '  prod         Install production dependencies only.'
        '  list-python  Show/select available Python interpreters.'
        '  self-update  Update this automation command and module.'
        '  help         Show this help.'
    )

    $text = ($lines -join [Environment]::NewLine)
    if ($Emit) {
        Write-Host $text
        return
    }
    return $text
}
