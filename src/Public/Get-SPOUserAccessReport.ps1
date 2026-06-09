function Get-SPOUserAccessReport {
    <#
    .SYNOPSIS
        Reports the SharePoint Online locations a given user can access (sites, libraries, folders, files).

    .DESCRIPTION
        Given a UPN, this:
          1. Resolves the user and their transitive Entra ID group membership (Microsoft Graph).
          2. Determines the sites in scope (explicit -SiteUrl list, or all sites via Get-PnPTenantSite).
          3. Crawls each site's security tree (web -> list -> folder/file) evaluating role assignments
             and sharing links, matching the user directly and through SharePoint / Entra groups.
          4. Writes a CSV of access locations plus a run summary and a limitations notes file.

        You must call Connect-SPOPermissions first (it establishes the interactive connection and stores
        the ClientId used to reconnect to each site).

        READ THE LIMITATIONS: this is a high-confidence approximation of access, not a guaranteed
        effective-permissions evaluation. See docs/LIMITATIONS.md and the generated .NOTES.txt.

    .PARAMETER UserPrincipalName
        The UPN of the user to report on, e.g. jane.doe@contoso.com.

    .PARAMETER SiteUrl
        Optional explicit site collection URL(s). If omitted, every site in the tenant is enumerated
        (requires SharePoint Administrator).

    .PARAMETER Depth
        Site = web level only. List = web + libraries/lists. File = web + list + folders/files
        (items with unique permissions). Default File.

    .PARAMETER OutputFolder
        Folder for the report files. Default: ./reports under the current location.

    .PARAMETER MaxItemsPerList
        When Depth=File, cap items inspected per list (0 = no cap). Guards very large libraries.

    .PARAMETER IncludeOneDrive
        Include personal OneDrive sites when enumerating the whole tenant.

    .PARAMETER IncludeHiddenLists
        Include hidden lists/libraries in the crawl.

    .PARAMETER ExcludeBroadAccess
        Exclude broad/potential access (Everyone / Everyone-except-external claims and
        Organization/Anyone sharing links). By default these ARE included and flagged as potential.

    .PARAMETER IncludeLimitedAccess
        Include the system "Limited Access" role in results. Off by default - SharePoint grants it
        automatically just to allow traversal to a child item, so it is noise rather than meaningful access.

    .PARAMETER PassThru
        Also return the access records to the pipeline (in addition to writing files).

    .EXAMPLE
        Connect-SPOPermissions -Url https://contoso.sharepoint.com -ClientId $appId
        Get-SPOUserAccessReport -UserPrincipalName jane.doe@contoso.com -SiteUrl https://contoso.sharepoint.com/sites/Finance

    .EXAMPLE
        # Whole-tenant discovery, libraries level only (faster)
        Get-SPOUserAccessReport -UserPrincipalName jane.doe@contoso.com -Depth List
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
        [string]$UserPrincipalName,

        [Parameter()]
        [string[]]$SiteUrl,

        [Parameter()]
        [ValidateSet('Site', 'List', 'File')]
        [string]$Depth = 'File',

        [Parameter()]
        [string]$OutputFolder = (Join-Path (Get-Location).Path 'reports'),

        [Parameter()]
        [int]$MaxItemsPerList = 0,

        [Parameter()]
        [switch]$IncludeOneDrive,

        [Parameter()]
        [switch]$IncludeHiddenLists,

        [Parameter()]
        [switch]$ExcludeBroadAccess,

        [Parameter()]
        [switch]$IncludeLimitedAccess,

        [Parameter()]
        [switch]$PassThru
    )

    if (-not $script:SPOPermissionsContext) {
        throw 'Not connected. Run Connect-SPOPermissions -Url <site> -ClientId <appId> first.'
    }
    Assert-SPOPnPModule

    $ctx = $script:SPOPermissionsContext
    $includeBroad = -not $ExcludeBroadAccess
    $startTime = Get-Date

    # 1) Resolve the target identity (Graph) on the current connection.
    $identity = Resolve-SPOUserIdentity -UserPrincipalName $UserPrincipalName
    Write-Verbose "Resolved $($identity.Upn) (Id $($identity.UserId)); $($identity.GroupObjectIds.Count) group(s)."

    # 2) Determine scope. Tenant enumeration needs the admin endpoint.
    if (-not $SiteUrl) {
        Write-Verbose "Connecting to admin endpoint $($ctx.AdminUrl) to enumerate sites..."
        Connect-PnPOnline -Url $ctx.AdminUrl -Interactive -ClientId $ctx.ClientId -ErrorAction Stop
    }
    $sites = @(Get-SPOSiteScope -SiteUrl $SiteUrl -IncludeOneDrive:$IncludeOneDrive)
    $scopeDescription = if ($SiteUrl) { "$($sites.Count) specified site(s)" } else { "All tenant sites ($($sites.Count))" }

    # 3) Crawl each site. One SharePoint token covers all sites in the tenant, so per-site
    #    reconnects are silent after the initial interactive sign-in.
    $records      = [System.Collections.Generic.List[object]]::new()
    $spGroupCache = @{}   # reset per site (SP group Ids are site-scoped)
    $sitesScanned = 0
    $errors       = [System.Collections.Generic.List[string]]::new()
    $i            = 0

    foreach ($site in $sites) {
        $i++
        Write-Progress -Activity "Crawling SharePoint sites for $($identity.Upn)" `
            -Status "[$i/$($sites.Count)] $site" -PercentComplete (($i / [math]::Max($sites.Count, 1)) * 100)

        $spGroupCache.Clear()
        try {
            Connect-PnPOnline -Url $site -Interactive -ClientId $ctx.ClientId -ErrorAction Stop
            $siteRecords = Get-SPOSecurableAccess -SiteUrl $site -Identity $identity -Depth $Depth `
                -SPGroupCache $spGroupCache -MaxItemsPerList $MaxItemsPerList `
                -IncludeHiddenLists:$IncludeHiddenLists -IncludeBroadClaims $includeBroad `
                -IncludeLimitedAccess $IncludeLimitedAccess.IsPresent -ClientId $ctx.ClientId
            foreach ($r in $siteRecords) { $records.Add($r) }
            $sitesScanned++
        }
        catch {
            $msg = "$site -> $($_.Exception.Message)"
            $errors.Add($msg)
            Write-Warning "Skipped $msg"
        }
    }
    Write-Progress -Activity "Crawling SharePoint sites for $($identity.Upn)" -Completed

    # 4) Write output.
    $runMeta = @{
        DisplayName      = $identity.DisplayName
        Depth            = $Depth
        ScopeDescription = $scopeDescription
        Duration         = ((Get-Date) - $startTime).ToString()
        SitesTotal       = $sites.Count
        SitesScanned     = $sitesScanned
        SitesError       = $errors.Count
        Errors           = $errors
    }

    $output = Write-SPOAccessOutput -Records $records.ToArray() -OutputFolder $OutputFolder `
        -UserPrincipalName $identity.Upn -RunMeta $runMeta

    Write-Host ""
    Write-Host "Report written for $($identity.Upn):" -ForegroundColor Green
    Write-Host "  CSV    : $($output.CsvPath)"
    Write-Host "  Summary: $($output.SummaryPath)"
    Write-Host "  Notes  : $($output.NotesPath)"
    Write-Host "  Rows   : $($output.RecordCount)  |  Sites scanned: $sitesScanned/$($sites.Count)"

    if ($PassThru) {
        return $records.ToArray()
    }
    return $output
}
