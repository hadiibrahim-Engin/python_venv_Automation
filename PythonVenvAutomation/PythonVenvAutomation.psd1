@{
    # Script module associated with this manifest.
    RootModule        = 'PythonVenvAutomation.psm1'

    # Version number of this module. SINGLE SOURCE OF TRUTH is the repo-root
    # VERSION file; build/Update-Version.ps1 keeps this value in sync and
    # build/Build.ps1 fails the build if the two ever diverge.
    ModuleVersion     = '1.0.0'

    # Unique identifier for this module.
    GUID              = 'b3d4f2a1-6c8e-4a2b-9f1d-2e7c5a9b0c34'

    Author            = 'Hadi Ibrahim'
    CompanyName       = 'Company'
    Copyright         = '(c) Hadi Ibrahim. All rights reserved.'
    Description       = 'Distributable Windows-only PowerShell automation that creates, repairs, signs, and activates a Python virtual environment. Exposes a single user-facing command (default: devsetup) with automatic self-updating.'

    # Works on Windows PowerShell 5.1 and PowerShell 7+.
    PowerShellVersion = '5.1'

    # Only the public surface is exported. Private helpers stay internal.
    FunctionsToExport = @(
        'Invoke-PythonVenvSetup',
        'Install-DevSetupCommand',
        'Update-PythonVenvAutomation',
        'Get-PythonVenvSetupInfo'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Python', 'venv', 'setup', 'automation', 'Windows', 'devsetup')
            ProjectUri   = 'https://REPLACE_WITH_COMPANY_TOOLS_URL/devsetup'
            ReleaseNotes = 'See repository CHANGELOG / Git history.'
        }
    }
}
