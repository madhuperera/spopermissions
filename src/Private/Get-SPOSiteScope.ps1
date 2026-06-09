function Get-SPOSiteScope {
    <#
    .SYNOPSIS
        Resolves the set of site collection URLs to crawl.

    .DESCRIPTION
        If explicit site URLs are supplied they are used as-is. Otherwise all site collections in the
        tenant are enumerated with Get-PnPTenantSite (requires SharePoint Administrator). Redirect
        sites and (unless requested) personal OneDrive sites are filtered out.

    .PARAMETER SiteUrl
        One or more explicit site collection URLs. When provided, tenant enumeration is skipped.

    .PARAMETER IncludeOneDrive
        Include personal OneDrive for Business sites (-my.sharepoint.com / personal/) in tenant enumeration.

    .OUTPUTS
        [string[]] of site collection URLs.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$SiteUrl,

        [Parameter()]
        [switch]$IncludeOneDrive
    )

    if ($SiteUrl) {
        Write-Verbose "Using $($SiteUrl.Count) explicitly supplied site URL(s)."
        return ($SiteUrl | ForEach-Object { $_.TrimEnd('/') } | Select-Object -Unique)
    }

    Write-Verbose 'Enumerating all site collections via Get-PnPTenantSite...'
    # Get-PnPTenantSite excludes OneDrive sites unless -IncludeOneDriveSites is passed, so the flag
    # must be threaded through here (filtering alone would never see them).
    $tenantParams = @{ ErrorAction = 'Stop' }
    if ($IncludeOneDrive) { $tenantParams['IncludeOneDriveSites'] = $true }

    $sites = Get-PnPTenantSite @tenantParams |
        Where-Object { $_.Template -ne 'RedirectSite#0' }

    if (-not $IncludeOneDrive) {
        # Belt-and-braces in case any personal sites slip through.
        $sites = $sites | Where-Object {
            $_.Url -notmatch '-my\.sharepoint\.com' -and $_.Template -notlike 'SPSPERS*'
        }
    }

    $urls = $sites | Select-Object -ExpandProperty Url | ForEach-Object { $_.TrimEnd('/') } | Select-Object -Unique
    Write-Verbose "Resolved $($urls.Count) site(s) in scope."
    return $urls
}
