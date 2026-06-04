# =============================================================================
# CommandName.ps1 - SINGLE SOURCE OF TRUTH for the user-facing command name.
# =============================================================================
#
# To rename the global command (for example from 'devsetup' to 'envctl'),
# change ONLY the value below, then reinstall/regenerate the shims:
#
#     Install-DevSetupCommand -Force
#
# Everything else - generated .ps1/.cmd shim names, help text, installer
# output, runtime config, PATH installation, tests, and README examples -
# derives the name from this value via Get-DevSetupCommandName. Do not
# hardcode the command name anywhere else in the codebase.
# =============================================================================

$Script:DevSetupCommandName = 'devsetup'
