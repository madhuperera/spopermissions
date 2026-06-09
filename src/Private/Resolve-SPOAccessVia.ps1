function Resolve-SPOAccessVia {
    <#
    .SYNOPSIS
        Evaluates a securable object's role assignments and returns how (if at all) the target user
        has access - including access granted through sharing links.

    .DESCRIPTION
        Loads the RoleAssignments of a SharePoint securable (web, list, or item), and for each
        assignment determines whether the principal grants the target user access:
          - Users / Entra groups / special claims -> Test-SPOMemberGrantsUser (leaf matching)
          - SharePoint groups                      -> expanded via Get-PnPGroupMember, then leaf-matched
          - SharingLinks.* groups                  -> classified as a sharing link (Specific/Organization/Anyone)

        Sharing a file/folder in SharePoint creates a hidden "SharingLinks.<guid>..." group on the item
        and breaks inheritance, so sharing-link access shows up naturally in role assignments. People in
        a "specific people" link appear as members of that group. "Organization"/"Anyone" links grant
        access via the link itself (no explicit member), so they are only reported when -IncludeBroadClaims
        is set, and flagged as potential (broad) access.

        SharePoint group expansion results are cached per group Id (in -SPGroupCache).

    .PARAMETER Securable
        A PnP/CSOM client object that has a RoleAssignments collection (web, list, or list item).

    .PARAMETER Identity
        Resolved identity from Resolve-SPOUserIdentity.

    .PARAMETER SPGroupCache
        Hashtable used to cache SharePoint group memberships across calls.

    .PARAMETER IncludeBroadClaims
        Treat "Everyone" / "Everyone except external users" claims AND broad (Organization/Anyone)
        sharing links as granting access. Default $true.

    .PARAMETER IncludeLimitedAccess
        Include the system "Limited Access" role (granted only to enable traversal). Default $false.

    .OUTPUTS
        Zero or more PSCustomObject with AccessVia, Roles, AccessType ('RoleAssignment'|'SharingLink'),
        and Notes - one per distinct access path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Securable,
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)] [hashtable]$SPGroupCache,
        [Parameter()] [bool]$IncludeBroadClaims = $true,
        [Parameter()] [bool]$IncludeLimitedAccess = $false
    )

    $limitedRoles = @('Limited Access', 'Web-Only Limited Access')
    Get-PnPProperty -ClientObject $Securable -Property RoleAssignments | Out-Null

    # AccessVia label -> @{ Roles = HashSet; Type = string; Notes = string }
    $matched = [ordered]@{}

    function Add-Match([string]$via, [string[]]$roles, [string]$type, [string]$notes) {
        if (-not $matched.Contains($via)) {
            $matched[$via] = @{
                Roles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                Type  = $type
                Notes = $notes
            }
        }
        foreach ($r in $roles) { [void]$matched[$via].Roles.Add($r) }
    }

    foreach ($ra in $Securable.RoleAssignments) {
        Get-PnPProperty -ClientObject $ra -Property Member, RoleDefinitionBindings | Out-Null
        $member = $ra.Member
        try {
            Get-PnPProperty -ClientObject $member -Property LoginName, Title, PrincipalType, Id, Email | Out-Null
        }
        catch { }

        $roles = @($ra.RoleDefinitionBindings | ForEach-Object { $_.Name })
        if (-not $IncludeLimitedAccess) {
            $roles = @($roles | Where-Object { $_ -notin $limitedRoles })
        }
        if (-not $roles) { continue }

        $principalType = [string]$member.PrincipalType
        $login = [string]$member.LoginName
        $title = [string]$member.Title

        if ($principalType -eq 'SharePointGroup') {
            $isSharing = ($login -like 'SharingLinks*') -or ($title -like 'SharingLinks*')

            if ($isSharing) {
                $scope = Get-SPOSharingLinkScope -Name "$title $login"
                $inner = Resolve-SPOSharePointGroupMatch -Group $member -Identity $Identity `
                            -SPGroupCache $SPGroupCache -IncludeBroadClaims $IncludeBroadClaims
                if ($inner) {
                    Add-Match "SharingLink:$scope" $roles 'SharingLink' 'User is an explicit target of this sharing link.'
                }
                elseif ($IncludeBroadClaims -and $scope -in 'Organization', 'Anyone') {
                    Add-Match "SharingLink:$scope" $roles 'SharingLink' 'Broad link - grants access without listing the user explicitly (potential access).'
                }
            }
            else {
                $inner = Resolve-SPOSharePointGroupMatch -Group $member -Identity $Identity `
                            -SPGroupCache $SPGroupCache -IncludeBroadClaims $IncludeBroadClaims
                if ($inner) {
                    $via = "SPGroup:$title"
                    if ($inner -ne 'member') { $via = "$via ($inner)" }
                    Add-Match $via $roles 'RoleAssignment' $null
                }
            }
        }
        else {
            $leaf = Test-SPOMemberGrantsUser -Member $member -Identity $Identity -IncludeBroadClaims $IncludeBroadClaims
            if ($leaf) {
                $notes = if ($leaf -in 'Everyone', 'EveryoneExceptExternal') { 'Broad claim - grants access to a large audience (potential access).' } else { $null }
                Add-Match $leaf $roles 'RoleAssignment' $notes
            }
        }
    }

    foreach ($via in $matched.Keys) {
        [pscustomobject]@{
            AccessVia  = $via
            Roles      = (($matched[$via].Roles | Sort-Object) -join ', ')
            AccessType = $matched[$via].Type
            Notes      = $matched[$via].Notes
        }
    }
}

function Resolve-SPOSharePointGroupMatch {
    <#
    .SYNOPSIS
        Returns an inner access label if the target user is a member of the given SharePoint group,
        otherwise $null. Expands (and caches) the group's membership.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Group,
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)] [hashtable]$SPGroupCache,
        [Parameter()] [bool]$IncludeBroadClaims = $true
    )

    $cacheKey = [string]$Group.Id
    if (-not $SPGroupCache.ContainsKey($cacheKey)) {
        $members = @()
        try {
            $members = @(Get-PnPGroupMember -Group $Group.Id -ErrorAction Stop)
        }
        catch {
            Write-Verbose "Could not expand SharePoint group '$($Group.Title)' (Id $cacheKey): $_"
        }
        $SPGroupCache[$cacheKey] = $members
    }

    foreach ($m in $SPGroupCache[$cacheKey]) {
        $leaf = Test-SPOMemberGrantsUser -Member $m -Identity $Identity -IncludeBroadClaims $IncludeBroadClaims
        if ($leaf) {
            return ($(if ($leaf -eq 'Direct') { 'member' } else { $leaf }))
        }
    }
    return $null
}

function Get-SPOSharingLinkScope {
    <#
    .SYNOPSIS
        Classifies a SharingLinks group name into a link scope: Specific, Organization, or Anyone.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    switch -Regex ($Name) {
        'Anonymous'    { return 'Anyone' }
        'Organization' { return 'Organization' }
        'Flexible'     { return 'Specific' }   # "specific people" links
        default        { return 'Specific' }
    }
}
