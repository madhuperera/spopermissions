function Get-SPOSecurableAccess {
    <#
    .SYNOPSIS
        Crawls a single connected SharePoint site for places the target user has access.

    .DESCRIPTION
        Walks the security tree of the currently connected site:
          Web (incl. subwebs) -> Lists/Libraries -> (optionally) Folders/Files

        Only objects with UNIQUE role assignments (broken inheritance) are evaluated, because objects
        that inherit are already covered by the nearest parent that has unique permissions. This both
        matches the SharePoint security model and keeps the crawl tractable. The site's root web always
        has unique permissions and is always evaluated.

        Requires that the caller has already connected to this site (Connect-PnPOnline).

    .PARAMETER SiteUrl
        The site collection URL (used for output labelling).

    .PARAMETER Identity
        Resolved identity from Resolve-SPOUserIdentity.

    .PARAMETER Depth
        Site  = web-level only.
        List  = web + list/library level.
        File  = web + list + folder/file (items with unique permissions). Slowest.

    .PARAMETER SPGroupCache
        Hashtable cache passed through to Resolve-SPOAccessVia.

    .PARAMETER MaxItemsPerList
        When Depth=File, cap how many items per list are inspected for unique permissions (0 = no cap).
        A guard against very large libraries.

    .PARAMETER IncludeHiddenLists
        Include hidden lists/libraries in the crawl.

    .PARAMETER IncludeBroadClaims
        Treat Everyone / Everyone-except-external claims as access. Default $true.

    .OUTPUTS
        Access record PSCustomObjects (see New-SPOAccessRecord).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SiteUrl,
        [Parameter(Mandatory)] $Identity,
        [Parameter()] [ValidateSet('Site', 'List', 'File')] [string]$Depth = 'File',
        [Parameter(Mandatory)] [hashtable]$SPGroupCache,
        [Parameter()] [int]$MaxItemsPerList = 0,
        [Parameter()] [switch]$IncludeHiddenLists,
        [Parameter()] [bool]$IncludeBroadClaims = $true,
        [Parameter()] [bool]$IncludeLimitedAccess = $false,
        [Parameter()] [string]$ClientId
    )

    # Collect the root web plus every subweb URL (from the current root connection).
    $rootUrl = $SiteUrl.TrimEnd('/')
    $webUrls = [System.Collections.Generic.List[string]]::new()
    $webUrls.Add($rootUrl)
    try {
        foreach ($sub in (Get-PnPSubWeb -Recurse -Includes Url -ErrorAction Stop)) {
            $u = ([string]$sub.Url).TrimEnd('/')
            if ($u -and $u -ne $rootUrl) { $webUrls.Add($u) }
        }
    }
    catch {
        Write-Verbose "Could not enumerate subwebs of $SiteUrl : $_"
    }

    foreach ($webUrl in $webUrls) {
        $isRoot = ($webUrl -eq $rootUrl)

        # Bind the connection to THIS web so Get-PnPList / Get-PnPListItem return its own lists.
        # (One SharePoint token covers the whole tenant, so subweb reconnects are silent.)
        if (-not $isRoot) {
            try {
                Connect-PnPOnline -Url $webUrl -Interactive -ClientId $ClientId -ErrorAction Stop
            }
            catch {
                Write-Verbose "Could not connect to subweb $webUrl : $_"
                continue
            }
        }

        $web = Get-PnPWeb -Includes HasUniqueRoleAssignments, Url, Title, ServerRelativeUrl

        # Evaluate a web only if it owns its permissions (root always does; subwebs only if broken).
        if ($isRoot -or $web.HasUniqueRoleAssignments) {
            foreach ($m in (Resolve-SPOAccessVia -Securable $web -Identity $Identity -SPGroupCache $SPGroupCache -IncludeBroadClaims $IncludeBroadClaims -IncludeLimitedAccess $IncludeLimitedAccess)) {
                New-SPOAccessRecord -SiteUrl $SiteUrl -ScopeType 'Web' -Title $web.Title `
                    -ObjectUrl $web.ServerRelativeUrl -AccessVia $m.AccessVia -Roles $m.Roles `
                    -AccessType $m.AccessType -Notes $m.Notes -InheritanceBroken (-not $isRoot)
            }
        }

        if ($Depth -eq 'Site') { continue }

        $lists = Get-PnPList -Includes HasUniqueRoleAssignments, Hidden, Title, BaseType, RootFolder, ItemCount
        foreach ($list in $lists) {
            if (-not $IncludeHiddenLists -and $list.Hidden) { continue }

            if ($list.HasUniqueRoleAssignments) {
                Get-PnPProperty -ClientObject $list -Property RootFolder | Out-Null
                foreach ($m in (Resolve-SPOAccessVia -Securable $list -Identity $Identity -SPGroupCache $SPGroupCache -IncludeBroadClaims $IncludeBroadClaims -IncludeLimitedAccess $IncludeLimitedAccess)) {
                    New-SPOAccessRecord -SiteUrl $SiteUrl -ScopeType 'List' -Title $list.Title `
                        -ObjectUrl $list.RootFolder.ServerRelativeUrl -AccessVia $m.AccessVia -Roles $m.Roles `
                        -AccessType $m.AccessType -Notes $m.Notes -InheritanceBroken $true
                }
            }

            if ($Depth -eq 'File') {
                Get-SPOListItemAccess -SiteUrl $SiteUrl -List $list -Identity $Identity `
                    -SPGroupCache $SPGroupCache -MaxItemsPerList $MaxItemsPerList `
                    -IncludeBroadClaims $IncludeBroadClaims -IncludeLimitedAccess $IncludeLimitedAccess
            }
        }
    }
}

function Get-SPOListItemAccess {
    <#
    .SYNOPSIS
        Inspects items in a list/library for those with unique permissions that grant the target user.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SiteUrl,
        [Parameter(Mandatory)] $List,
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)] [hashtable]$SPGroupCache,
        [Parameter()] [int]$MaxItemsPerList = 0,
        [Parameter()] [bool]$IncludeBroadClaims = $true,
        [Parameter()] [bool]$IncludeLimitedAccess = $false
    )

    $isDocLib = ([string]$List.BaseType -eq 'DocumentLibrary')
    $inspected = 0

    try {
        $items = Get-PnPListItem -List $List -PageSize 500 -Fields 'FileRef', 'FileLeafRef', 'FileSystemObjectType' -ErrorAction Stop
    }
    catch {
        Write-Verbose "Could not enumerate items in list '$($List.Title)': $_"
        return
    }

    foreach ($item in $items) {
        if ($MaxItemsPerList -gt 0 -and $inspected -ge $MaxItemsPerList) {
            Write-Verbose "Reached MaxItemsPerList ($MaxItemsPerList) for '$($List.Title)'; stopping item scan."
            break
        }
        $inspected++

        $hasUnique = $false
        try { $hasUnique = Get-PnPProperty -ClientObject $item -Property HasUniqueRoleAssignments }
        catch { continue }
        if (-not $hasUnique) { continue }

        $isFolder = ([string]$item.FileSystemObjectType -eq 'Folder')
        $scopeType = if ($isFolder) { 'Folder' } elseif ($isDocLib) { 'File' } else { 'ListItem' }
        $objUrl = [string]$item['FileRef']
        $title  = [string]$item['FileLeafRef']

        foreach ($m in (Resolve-SPOAccessVia -Securable $item -Identity $Identity -SPGroupCache $SPGroupCache -IncludeBroadClaims $IncludeBroadClaims -IncludeLimitedAccess $IncludeLimitedAccess)) {
            New-SPOAccessRecord -SiteUrl $SiteUrl -ScopeType $scopeType -Title $title `
                -ObjectUrl $objUrl -AccessVia $m.AccessVia -Roles $m.Roles `
                -AccessType $m.AccessType -Notes $m.Notes -InheritanceBroken $true
        }
    }
}
