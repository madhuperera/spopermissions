@{
    RootModule        = 'SPOPermissions.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b8f3a2d1-6c4e-4f9a-9b2e-7d1c0a5e3f44'
    Author            = 'Sonitlo'
    CompanyName       = 'Sonitlo'
    Copyright         = '(c) Sonitlo. All rights reserved.'
    Description       = 'Reports SharePoint Online access for a specific user account (sites, libraries, folders, files) for audit, discovery, and client reporting. Built on PnP PowerShell.'

    PowerShellVersion = '7.2'

    # PnP.PowerShell is required at runtime. It is intentionally NOT a hard RequiredModules
    # dependency so the module can be imported for inspection/testing without it installed.
    # Connect-SPOPermissions verifies its presence before connecting.
    RequiredModules   = @()

    FunctionsToExport = @(
        'Connect-SPOPermissions',
        'Disconnect-SPOPermissions',
        'Get-SPOUserAccessReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('SharePoint', 'SharePointOnline', 'Permissions', 'Audit', 'PnP', 'Reporting', 'Microsoft365')
            ProjectUri   = 'https://github.com/sonitlo/spopermissions'
            LicenseUri   = 'https://github.com/sonitlo/spopermissions/blob/main/LICENSE'
            ReleaseNotes = 'Initial release: interactive per-user SharePoint Online access reporting down to files/folders with unique permissions, plus sharing-link capture.'
        }
    }
}
