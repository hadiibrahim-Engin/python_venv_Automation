# Test stub module. Stands in for the real PythonVenvAutomation when exercising
# the generated command shim, so dispatch/mapping can be asserted WITHOUT ever
# running the real Python setup pipeline. Each command prints a JSON record of
# the bound parameters it received.

function Invoke-PythonVenvSetup {
    [CmdletBinding()]
    param(
        [string] $ProjectRoot,
        [string] $PythonExePath,
        [switch] $UpdateDependencies,
        [switch] $PinExact,
        [switch] $ExcludeDev,
        [switch] $DryRun,
        [switch] $ListMode,
        [string] $PackageManager = 'auto',
        [string] $Mode = 'setup',
        [switch] $ContinueOnPrecheckFailure,
        [Alias('RecreateVenv')] [switch] $ForceRecreateVenv,
        [switch] $NonInteractive,
        [object] $EnableCodeSigning,
        [string] $DigiCertUtilityExe,
        [switch] $KernelDriverSigning,
        [switch] $SignPoetryOnly,
        [object] $RequirePmShimSigning,
        [string] $PinnedPoetryVersion,
        [string] $PinnedUvVersion,
        [switch] $AllowPythonInstall,
        [switch] $SkipPythonInstall,
        [string] $UpgradePackage,
        [switch] $UnblockScripts
    )
    $o = [ordered]@{ Cmd = 'Invoke' }
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { $o[$k] = [bool]$v.IsPresent }
        else { $o[$k] = "$v" }
    }
    [pscustomobject]$o | ConvertTo-Json -Compress | Write-Output
}

function Update-PythonVenvAutomation {
    [CmdletBinding()]
    param()
    [pscustomobject]@{ Cmd = 'Update' } | ConvertTo-Json -Compress | Write-Output
}

Export-ModuleMember -Function Invoke-PythonVenvSetup, Update-PythonVenvAutomation
