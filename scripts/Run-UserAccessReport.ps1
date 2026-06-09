<#
.SYNOPSIS
    Example wrapper: connect and run a SharePoint Online per-user access report end to end.

.DESCRIPTION
    Thin convenience script around the SPOPermissions module. Reads optional defaults from
    config/settings.json (Url, ClientId), connects interactively, runs Get-SPOUserAccessReport, and
    disconnects. Intended as a starting point you copy/adapt per engagement.

.PARAMETER UserPrincipalName
    UPN of the user to report on.

.PARAMETER SiteUrl
    Optional explicit site URL(s). If omitted, the whole tenant is enumerated.

.PARAMETER Depth
    Site | List | File. Default File.

.PARAMETER Url
    SharePoint URL to connect to (tenant root or admin). Overrides config.

.PARAMETER ClientId
    Entra ID app (client) id for PnP. Overrides config.

.PARAMETER OutputFolder
    Where to write the report. Default ./reports.

.EXAMPLE
    ./scripts/Run-UserAccessReport.ps1 -UserPrincipalName jane.doe@contoso.com `
        -SiteUrl https://contoso.sharepoint.com/sites/Finance

.EXAMPLE
    ./scripts/Run-UserAccessReport.ps1 -UserPrincipalName jane.doe@contoso.com -Depth List
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$UserPrincipalName,
    [Parameter()] [string[]]$SiteUrl,
    [Parameter()] [ValidateSet('Site', 'List', 'File')] [string]$Depth = 'File',
    [Parameter()] [string]$Url,
    [Parameter()] [string]$ClientId,
    [Parameter()] [string]$OutputFolder,
    [Parameter()] [int]$MaxItemsPerList = 0,
    [Parameter()] [switch]$IncludeOneDrive,
    [Parameter()] [switch]$IncludeHiddenLists,
    [Parameter()] [switch]$ExcludeBroadAccess
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# Load defaults from config/settings.json if present.
$settings = @{}
$settingsPath = Join-Path $repoRoot 'config/settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
}

if (-not $Url) { $Url = $settings.Url }
if (-not $ClientId) { $ClientId = $settings.ClientId }
if (-not $OutputFolder) {
    $OutputFolder = if ($settings.OutputFolder) { $settings.OutputFolder } else { Join-Path $repoRoot 'reports' }
}

if (-not $Url -or -not $ClientId) {
    throw 'Url and ClientId are required (pass as parameters or set them in config/settings.json). See config/settings.sample.json.'
}

Import-Module (Join-Path $repoRoot 'src/SPOPermissions.psd1') -Force

try {
    Connect-SPOPermissions -Url $Url -ClientId $ClientId | Out-Null

    $params = @{
        UserPrincipalName  = $UserPrincipalName
        Depth              = $Depth
        OutputFolder       = $OutputFolder
        MaxItemsPerList    = $MaxItemsPerList
        IncludeOneDrive    = $IncludeOneDrive
        IncludeHiddenLists = $IncludeHiddenLists
        ExcludeBroadAccess = $ExcludeBroadAccess
    }
    if ($SiteUrl) { $params['SiteUrl'] = $SiteUrl }

    Get-SPOUserAccessReport @params
}
finally {
    Disconnect-SPOPermissions
}
