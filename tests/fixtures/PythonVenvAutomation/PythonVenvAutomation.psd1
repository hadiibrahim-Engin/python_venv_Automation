@{
    RootModule        = 'PythonVenvAutomation.psm1'
    ModuleVersion     = '99.0.0'
    GUID              = 'c1a2b3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d'
    Author            = 'test'
    Description       = 'Test stub that records dispatched commands instead of running the real setup pipeline.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-PythonVenvSetup', 'Update-PythonVenvAutomation')
}
