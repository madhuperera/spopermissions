function Resolve-SPOUserIdentity {
    <#
    .SYNOPSIS
        Resolves a UPN to the identity facts needed to match SharePoint role assignments.

    .DESCRIPTION
        Returns the user's Entra object id, the set of login/email forms used for DIRECT matching,
        and the set of Entra group object ids the user belongs to (transitive) used for INDIRECT
        matching against role assignments granted to Entra ID security / Microsoft 365 groups.

        Group membership is read from Microsoft Graph via the existing PnP connection
        (Invoke-PnPGraphMethod), so the Entra app registration needs delegated GroupMember.Read.All
        (and User.Read.All) with admin consent.

    .PARAMETER UserPrincipalName
        The UPN of the user to resolve, e.g. jane.doe@contoso.com.

    .OUTPUTS
        PSCustomObject with: Upn, UserId, DisplayName, Mail, DirectMatchKeys (string[]),
        GroupObjectIds ([System.Collections.Generic.HashSet[string]]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName
    )

    $upn = $UserPrincipalName.Trim().ToLowerInvariant()

    Write-Verbose "Resolving user $upn via Microsoft Graph..."
    $user = $null
    try {
        $user = Invoke-PnPGraphMethod -Url "v1.0/users/$upn`?`$select=id,userPrincipalName,displayName,mail" -Method Get -ErrorAction Stop
    }
    catch {
        throw "Could not resolve user '$UserPrincipalName' via Microsoft Graph. Verify the UPN and that the app has User.Read.All consented. Underlying error: $_"
    }

    # Group object ids the user effectively belongs to. We union two sources:
    #   1. transitiveMemberOf  -> groups the user is a (nested) MEMBER of
    #   2. ownedObjects        -> groups the user OWNS but may not be a member of
    # SharePoint can grant access to M365 group OWNERS via the "..._o" owners claim, and Graph's
    # transitiveMemberOf does NOT return owned-not-member groups - so we add ownedObjects to avoid
    # false negatives for owner-based access.
    $groupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($rel in @(
            "v1.0/users/$($user.id)/transitiveMemberOf/microsoft.graph.group?`$select=id&`$top=999",
            "v1.0/users/$($user.id)/ownedObjects/microsoft.graph.group?`$select=id&`$top=999"
        )) {
        try {
            $resp = Invoke-PnPGraphMethod -Url $rel -Method Get -All -ConsistencyLevelEventual -ErrorAction Stop
            # -All may return an object exposing .value, or the aggregated collection directly.
            $items = if ($null -ne $resp.value) { $resp.value } else { $resp }
            foreach ($g in $items) {
                if ($g.id) { [void]$groupIds.Add([string]$g.id) }
            }
        }
        catch {
            Write-Warning "Could not fully read group membership from '$rel': $_. Indirect (group-based) access may be under-reported."
        }
    }
    Write-Verbose "User belongs to / owns $($groupIds.Count) Entra group(s)."

    # Keys used to match a role-assignment principal directly to this user.
    $directKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($k in @($upn, $user.userPrincipalName, $user.mail, "i:0#.f|membership|$upn")) {
        if (-not [string]::IsNullOrWhiteSpace($k)) { $directKeys.Add($k.ToLowerInvariant()) | Out-Null }
    }

    [pscustomobject]@{
        Upn             = $upn
        UserId          = [string]$user.id
        DisplayName     = [string]$user.displayName
        Mail            = [string]$user.mail
        DirectMatchKeys = ($directKeys | Select-Object -Unique)
        GroupObjectIds  = $groupIds
    }
}
