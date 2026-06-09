function Get-SPOClaimObjectId {
    <#
    .SYNOPSIS
        Parses a SharePoint Online login/claim string into a principal kind + Entra object id.

    .DESCRIPTION
        SharePoint represents directory principals using encoded claim strings. This pure function
        classifies the claim and, where applicable, extracts the Entra ID object id so it can be
        matched against a user's transitive group membership.

        Recognised forms (common cases):
          i:0#.f|membership|user@contoso.com                         -> User
          c:0t.c|tenant|<guid>                                       -> EntraGroup (security group)
          c:0o.c|federateddirectoryclaimprovider|<guid>             -> M365Group (members)
          c:0o.c|federateddirectoryclaimprovider|<guid>_o           -> M365Group (owners)
          c:0-.f|rolemanager|spo-grid-all-users/<tenantid>          -> EveryoneExceptExternal
          c:0(.s|true                                                -> Everyone (incl. external)

    .PARAMETER LoginName
        The SharePoint principal LoginName / claim string.

    .OUTPUTS
        PSCustomObject with Kind ('User','EntraGroup','M365Group','EveryoneExceptExternal',
        'Everyone','Unknown') and ObjectId (guid string or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LoginName
    )

    $login = ($LoginName ?? '').Trim()
    $guidPattern = '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

    $kind = 'Unknown'
    $objectId = $null

    switch -Regex ($login) {
        '^c:0\(\.s\|true$'                               { $kind = 'Everyone'; break }
        '^c:0-\.f\|rolemanager\|spo-grid-all-users'      { $kind = 'EveryoneExceptExternal'; break }
        '^c:0t\.c\|tenant\|'                             { $kind = 'EntraGroup'; break }
        '^c:0o\.c\|federateddirectoryclaimprovider\|'    { $kind = 'M365Group'; break }
        '^i:0#\.f\|membership\|'                          { $kind = 'User'; break }
        default                                          { $kind = 'Unknown' }
    }

    if ($kind -in 'EntraGroup', 'M365Group') {
        $m = [regex]::Match($login, $guidPattern)
        if ($m.Success) { $objectId = $m.Value }
    }

    [pscustomobject]@{
        Kind     = $kind
        ObjectId = $objectId
    }
}
