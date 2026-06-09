function Connect-SPOPermissions {
    <#
    .SYNOPSIS
        Connects to SharePoint Online using PnP PowerShell with interactive admin sign-in.

    .DESCRIPTION
        Wraps Connect-PnPOnline -Interactive and stores connection context (ClientId, tenant
        root/admin URLs) at module scope so that Get-SPOUserAccessReport can re-connect to each
        in-scope site during a crawl.

        Since September 2024 the shared "PnP Management Shell" multi-tenant app was retired, so an
        Entra ID application registration that YOU own is required. See README.md for one-time setup.

        The signed-in account must be a SharePoint Administrator (or Global Administrator) to
        enumerate all site collections in a tenant-wide run.

    .PARAMETER Url
        A SharePoint Online URL to connect to. Accepts the tenant root
        (https://contoso.sharepoint.com), the admin URL (https://contoso-admin.sharepoint.com), or
        any site URL. The tenant root and admin URLs are derived automatically from whatever you pass.

    .PARAMETER ClientId
        The Application (client) ID of your Entra ID app registration used by PnP PowerShell.

    .PARAMETER Tenant
        Optional tenant id or domain (e.g. contoso.onmicrosoft.com). Passed through to Connect-PnPOnline.

    .EXAMPLE
        Connect-SPOPermissions -Url https://contoso.sharepoint.com -ClientId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

    .NOTES
        Built on PnP PowerShell (community, .NET Foundation) - not covered by a Microsoft SLA.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https://[^/]+\.sharepoint\.(com|us|de|cn)')]
        [string]$Url,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$ClientId,

        [Parameter()]
        [string]$Tenant
    )

    Assert-SPOPnPModule

    # Derive tenant root + admin URLs from whatever URL was supplied.
    # NOTE: avoid the automatic variable $host - use $spHost.
    $uri    = [uri]$Url
    $spHost = $uri.Host                                 # e.g. contoso.sharepoint.com or contoso-admin.sharepoint.com
    $rootHost  = $spHost -replace '-admin\.sharepoint', '.sharepoint'
    $adminHost = $rootHost -replace '\.sharepoint', '-admin.sharepoint'
    $rootUrl   = "https://$rootHost"
    $adminUrl  = "https://$adminHost"

    $connectParams = @{
        Url         = $Url
        Interactive = $true
        ClientId    = $ClientId
        ErrorAction = 'Stop'
    }
    if ($Tenant) { $connectParams['Tenant'] = $Tenant }

    Write-Verbose "Connecting interactively to $Url (ClientId $ClientId)..."
    $connection = Connect-PnPOnline @connectParams

    $script:SPOPermissionsContext = [pscustomobject]@{
        ClientId   = $ClientId
        Tenant     = $Tenant
        RootUrl    = $rootUrl
        AdminUrl   = $adminUrl
        ConnectedAt = Get-Date
    }

    Write-Verbose "Connected. Tenant root: $rootUrl ; Admin: $adminUrl"
    return $script:SPOPermissionsContext
}
