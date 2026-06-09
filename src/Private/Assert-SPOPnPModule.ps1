function Assert-SPOPnPModule {
    <#
    .SYNOPSIS
        Ensures the PnP.PowerShell module is available, importing it if necessary.

    .DESCRIPTION
        SPOPermissions depends on PnP.PowerShell at runtime. This guard gives a clear, actionable
        error rather than a confusing "command not found" if the module is missing.
    #>
    [CmdletBinding()]
    param()

    if (Get-Command -Name Connect-PnPOnline -ErrorAction SilentlyContinue) {
        return
    }

    if (Get-Module -ListAvailable -Name 'PnP.PowerShell' -ErrorAction SilentlyContinue) {
        Import-Module 'PnP.PowerShell' -ErrorAction Stop
        return
    }

    throw @'
PnP.PowerShell is not installed. Install it with:

    Install-Module PnP.PowerShell -Scope CurrentUser

Then ensure you have registered your own Entra ID app (see README.md - "One-time setup").
'@
}
