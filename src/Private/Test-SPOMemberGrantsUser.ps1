function Test-SPOMemberGrantsUser {
    <#
    .SYNOPSIS
        Determines whether a single LEAF SharePoint principal grants access to the target user.

    .DESCRIPTION
        Pure matching logic for leaf principals (Users and directory groups / special claims).
        SharePoint *groups* are not leaves - the caller (Resolve-SPOAccessVia) expands them first
        and feeds each expanded member into this function.

        Returns an "AccessVia" label string when the principal grants the user access, otherwise $null.

    .PARAMETER Member
        A SharePoint principal object exposing LoginName, Email (optional), Title (optional),
        and PrincipalType (optional). Works with both PnP/CSOM objects and plain hashtables/PSCustomObjects.

    .PARAMETER Identity
        The resolved identity from Resolve-SPOUserIdentity (DirectMatchKeys, GroupObjectIds).

    .PARAMETER IncludeBroadClaims
        When set, "Everyone" and "Everyone except external users" claims are treated as granting the
        user access (returns 'Everyone' / 'EveryoneExceptExternal'). Defaults to $true because these
        DO grant the user access; callers can disable to report only explicit grants.

    .OUTPUTS
        [string] AccessVia label, or $null when there is no match.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Member,

        [Parameter(Mandatory)]
        $Identity,

        [Parameter()]
        [bool]$IncludeBroadClaims = $true
    )

    $login = [string]$Member.LoginName
    $email = [string]$Member.Email

    # 1) Direct user match by email / upn / claim form.
    $candidateKeys = @($login, $email) | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() }
    foreach ($key in $candidateKeys) {
        if ($Identity.DirectMatchKeys -contains $key) {
            return 'Direct'
        }
        # claim login often embeds the upn: i:0#.f|membership|user@contoso.com
        foreach ($dk in $Identity.DirectMatchKeys) {
            if ($dk -notmatch '\|' -and $key.EndsWith("|$dk")) { return 'Direct' }
        }
    }

    # 2) Directory group / special claim match.
    $claim = Get-SPOClaimObjectId -LoginName $login
    switch ($claim.Kind) {
        { $_ -in 'EntraGroup', 'M365Group' } {
            if ($claim.ObjectId -and $Identity.GroupObjectIds.Contains($claim.ObjectId)) {
                $title = [string]$Member.Title
                $label = if ($title) { "EntraGroup:$title" } else { "EntraGroup:$($claim.ObjectId)" }
                return $label
            }
        }
        'Everyone' {
            if ($IncludeBroadClaims) { return 'Everyone' }
        }
        'EveryoneExceptExternal' {
            if ($IncludeBroadClaims) { return 'EveryoneExceptExternal' }
        }
    }

    return $null
}
