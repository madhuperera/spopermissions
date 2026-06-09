function New-SPOAccessRecord {
    <#
    .SYNOPSIS
        Factory for a single access-report record - the unit emitted to the CSV.

    .DESCRIPTION
        Centralises the output schema so every code path (web/list/item role assignments and sharing
        links) produces identically-shaped objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SiteUrl,
        [Parameter(Mandatory)] [ValidateSet('Web', 'List', 'Folder', 'File', 'ListItem')] [string]$ScopeType,
        [Parameter()] [string]$Title,
        [Parameter()] [string]$ObjectUrl,
        [Parameter()] [string]$AccessVia,
        [Parameter()] [string]$Roles,
        [Parameter()] [ValidateSet('RoleAssignment', 'SharingLink')] [string]$AccessType = 'RoleAssignment',
        [Parameter()] [bool]$InheritanceBroken,
        [Parameter()] [string]$Notes
    )

    [pscustomobject]@{
        SiteUrl           = $SiteUrl
        ScopeType         = $ScopeType
        Title             = $Title
        ObjectUrl         = $ObjectUrl
        AccessType        = $AccessType
        AccessVia         = $AccessVia
        Roles             = $Roles
        InheritanceBroken = $InheritanceBroken
        Notes             = $Notes
    }
}
