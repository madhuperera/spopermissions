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

    # Transitive group membership (paged). microsoft.graph.group filter excludes directory roles etc.
    $groupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $next = "v1.0/users/$($user.id)/transitiveMemberOf/microsoft.graph.group?`$select=id,displayName&`$top=999"
    while ($next) {
        $page = Invoke-PnPGraphMethod -Url $next -Method Get -ErrorAction Stop
        foreach ($g in $page.value) {
            if ($g.id) { [void]$groupIds.Add([string]$g.id) }
        }
        $next = $page.'@odata.nextLink'
    }
    Write-Verbose "User belongs to $($groupIds.Count) Entra group(s) (transitive)."

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
