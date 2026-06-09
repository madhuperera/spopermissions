<#
.SYNOPSIS
    Tier 0 resilient orchestration: run the SharePoint Online per-user access report ONE SITE AT A
    TIME, persisting each site's output as it completes, with resume and a growing log.

.DESCRIPTION
    The module's Get-SPOUserAccessReport accumulates every record in memory and writes the CSV only
    once, at the very end of the whole crawl. On a large, multi-day tenant run that means a crash,
    reboot, or Ctrl-C before that final write loses ALL collected data, with no visibility into how
    far it got.

    This wrapper changes the failure model WITHOUT touching the module. It calls Get-SPOUserAccessReport
    once PER SITE, each into its own output sub-folder. Because every per-site call writes its own
    complete CSV + summary + notes, you get:

      * Durable incremental output - a finished report appears per site as it completes.
      * Crash blast radius of one site - a kill loses only the in-flight site, never the whole run.
      * Resume - re-run with the SAME -OutputFolder and already-completed sites are skipped
        (tracked in manifest.csv at the run-folder root).
      * Interruptibility - Ctrl-C between sites loses nothing; the finally block still merges whatever
        completed, disconnects, and stops the transcript.
      * Visibility - a growing transcript (run.log) you can tail live, plus manifest.csv.

    Trade-off: the target identity + transitive group membership is re-resolved on each per-site call
    (a few seconds per site). That is the price of per-site isolation and is acceptable for long runs.

    This script adds NO dependency on the module's internals - it only calls the public
    Connect-SPOPermissions / Get-SPOUserAccessReport / Disconnect-SPOPermissions and PnP's
    Get-PnPTenantSite for enumeration.

.PARAMETER UserPrincipalName
    UPN of the user to report on.

.PARAMETER SiteUrl
    Explicit site URL(s) to process. If omitted (and -SiteListPath not given) the whole tenant is
    enumerated via Get-PnPTenantSite (requires SharePoint Administrator).

.PARAMETER SiteListPath
    Path to a text file with one site URL per line (blank lines and lines starting with # are ignored).
    Handy for a fixed, reviewable scope and for deterministic resume.

.PARAMETER Depth
    Site | List | File. Default File.

.PARAMETER MaxItemsPerList
    Caps how many items are inspected per list/library when -Depth File (0 = no cap, the default).

    IMPORTANT - this is a COUNT cap, NOT a folder-depth selector. Under the hood Get-PnPListItem
    returns every item in the library as one FLAT stream - files AND folder objects, across ALL
    nesting levels - ordered by list item id (creation order), not by folder hierarchy. The crawl
    inspects items in that order and stops once N have been inspected.

    Consequently there is NO value of N that means "scan down to DocumentLibrary\RootFolder\Folder1
    level". A first-level folder such as Folder1 is just one item somewhere in that flat stream; with
    a small N you may stop before ever reaching it (e.g. N files buried in one deep subfolder) and
    miss Folder1 entirely. To be CERTAIN every first-level folder is inspected you must set N = 0
    (unlimited) - or, equivalently, N >= the library's total item count. Note that folder objects
    themselves count toward N.

    So use -MaxItemsPerList only as a throughput / runaway guard, never to express depth. A true
    "folders-only" or "first level only" scan would require a module change (Tier 1).

.PARAMETER Url
    SharePoint URL to connect to (tenant root or admin). Overrides config/settings.json.

.PARAMETER ClientId
    Entra ID app (client) id for PnP. Overrides config/settings.json.

.PARAMETER OutputFolder
    The run folder. Each site writes to a sub-folder here; manifest.csv and run.log live at its root;
    a merged CSV is written under _combined. Re-run with the SAME folder to RESUME (already-completed
    sites are skipped). Default: reports/SiteBySite_<user>_<timestamp>.

.PARAMETER IncludeOneDrive
    Include personal OneDrive sites in tenant enumeration.

.PARAMETER IncludeHiddenLists
    Include hidden lists/libraries in the crawl.

.PARAMETER ExcludeBroadAccess
    Exclude Everyone / Org / Anyone (broad) access.

.EXAMPLE
    # Whole tenant, one site at a time, full file depth, resumable
    ./scripts/Invoke-SiteBySiteReport.ps1 -UserPrincipalName jane.doe@contoso.com

.EXAMPLE
    # Fixed scope from a file; resume later by pointing at the same run folder
    ./scripts/Invoke-SiteBySiteReport.ps1 -UserPrincipalName jane.doe@contoso.com `
        -SiteListPath ./config/sites.txt `
        -OutputFolder ./reports/SiteBySite_jane_20260610_101500

.EXAMPLE
    # Guarantee full folder coverage of named sites (no per-list cap)
    ./scripts/Invoke-SiteBySiteReport.ps1 -UserPrincipalName jane.doe@contoso.com `
        -SiteUrl https://contoso.sharepoint.com/sites/Finance -Depth File -MaxItemsPerList 0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$UserPrincipalName,
    [Parameter()] [string[]]$SiteUrl,
    [Parameter()] [string]$SiteListPath,
    [Parameter()] [ValidateSet('Site', 'List', 'File')] [string]$Depth = 'File',
    [Parameter()] [int]$MaxItemsPerList = 0,
    [Parameter()] [string]$Url,
    [Parameter()] [string]$ClientId,
    [Parameter()] [string]$OutputFolder,
    [Parameter()] [switch]$IncludeOneDrive,
    [Parameter()] [switch]$IncludeHiddenLists,
    [Parameter()] [switch]$ExcludeBroadAccess
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function ConvertTo-SafeName {
    param([string]$Value)
    $s = $Value -replace '^https?://', '' -replace '[^a-zA-Z0-9._-]', '_'
    if ($s.Length -gt 120) { $s = $s.Substring(0, 120) }
    return $s.Trim('_')
}

# --- Resolve connection defaults from config/settings.json (same convention as Run-UserAccessReport.ps1) ---
$settings = @{}
$settingsPath = Join-Path $repoRoot 'config/settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
}
if (-not $Url) { $Url = $settings.Url }
if (-not $ClientId) { $ClientId = $settings.ClientId }
if (-not $Url -or -not $ClientId) {
    throw 'Url and ClientId are required (pass as parameters or set them in config/settings.json). See config/settings.sample.json.'
}

# --- Run folder (the resume key). Reusing an existing folder continues that run. ---
$safeUser = ($UserPrincipalName -replace '[^a-zA-Z0-9._-]', '_')
if (-not $OutputFolder) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputFolder = Join-Path $repoRoot "reports/SiteBySite_${safeUser}_${stamp}"
}
if (-not (Test-Path -LiteralPath $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}
$runFolder    = (Resolve-Path -LiteralPath $OutputFolder).Path
$manifestPath = Join-Path $runFolder 'manifest.csv'
$logPath      = Join-Path $runFolder 'run.log'

if ($MaxItemsPerList -gt 0 -and $Depth -eq 'File') {
    Write-Warning ("MaxItemsPerList = {0}: this is a COUNT cap, not a folder-depth limit. Items are " -f $MaxItemsPerList +
        'inspected in a flat id order, so a small cap can miss first-level folders entirely. Use 0 for full folder coverage.')
}

Import-Module (Join-Path $repoRoot 'src/SPOPermissions.psd1') -Force

# --- Load the resume set: sites already marked Done in a prior run of this folder. ---
# Case-insensitive: SharePoint URLs are not case-sensitive, so the skip must not be either.
$done = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $manifestPath) {
    Import-Csv -LiteralPath $manifestPath |
        Where-Object { $_.Status -eq 'Done' } |
        ForEach-Object { $done[$_.SiteUrl] = $true }
    Write-Host "Resuming run in $runFolder - $($done.Count) site(s) already complete will be skipped." -ForegroundColor Cyan
}

$transcriptStarted = $false
try {
    try { Start-Transcript -LiteralPath $logPath -Append | Out-Null; $transcriptStarted = $true }
    catch { Write-Warning "Could not start transcript ($logPath): $($_.Exception.Message)" }

    Connect-SPOPermissions -Url $Url -ClientId $ClientId | Out-Null

    # --- Build the site list ---------------------------------------------------------------------
    $sites = @()
    if ($SiteUrl) {
        $sites = $SiteUrl | ForEach-Object { $_.TrimEnd('/') }
    }
    elseif ($SiteListPath) {
        if (-not (Test-Path -LiteralPath $SiteListPath)) { throw "SiteListPath not found: $SiteListPath" }
        $sites = Get-Content -LiteralPath $SiteListPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            ForEach-Object { $_.TrimEnd('/') }
    }
    else {
        # Tenant-wide enumeration needs the admin endpoint. Derive it from the supplied Url.
        $uri       = [uri]$Url
        $rootHost  = $uri.Host -replace '-admin\.sharepoint', '.sharepoint'
        $adminHost = $rootHost -replace '\.sharepoint', '-admin.sharepoint'
        $adminUrl  = "https://$adminHost"
        Write-Host "Enumerating tenant sites via $adminUrl ..." -ForegroundColor Cyan
        Connect-PnPOnline -Url $adminUrl -Interactive -ClientId $ClientId -ErrorAction Stop

        $tenantParams = @{ ErrorAction = 'Stop' }
        if ($IncludeOneDrive) { $tenantParams['IncludeOneDriveSites'] = $true }
        $raw = Get-PnPTenantSite @tenantParams | Where-Object { $_.Template -ne 'RedirectSite#0' }
        if (-not $IncludeOneDrive) {
            $raw = $raw | Where-Object { $_.Url -notmatch '-my\.sharepoint\.com' -and $_.Template -notlike 'SPSPERS*' }
        }
        $sites = $raw | Select-Object -ExpandProperty Url | ForEach-Object { $_.TrimEnd('/') }
    }
    $sites = @($sites | Select-Object -Unique)
    Write-Host "Sites in scope: $($sites.Count)  |  Depth: $Depth  |  MaxItemsPerList: $MaxItemsPerList" -ForegroundColor Cyan

    # --- Crawl one site at a time, recording each outcome to the manifest as it finishes ----------
    $idx = 0
    foreach ($site in $sites) {
        $idx++
        if ($done.ContainsKey($site)) {
            Write-Host "[$idx/$($sites.Count)] SKIP (already done): $site"
            continue
        }

        Write-Host "[$idx/$($sites.Count)] $site" -ForegroundColor Green
        $siteFolder = Join-Path $runFolder (ConvertTo-SafeName $site)
        $status = 'Error'; $rows = 0; $csvPath = ''
        try {
            $res = Get-SPOUserAccessReport -UserPrincipalName $UserPrincipalName -SiteUrl $site `
                -Depth $Depth -OutputFolder $siteFolder -MaxItemsPerList $MaxItemsPerList `
                -IncludeHiddenLists:$IncludeHiddenLists -ExcludeBroadAccess:$ExcludeBroadAccess
            $status  = 'Done'
            $rows    = $res.RecordCount
            $csvPath = $res.CsvPath
        }
        catch {
            Write-Warning "Site failed: $site -> $($_.Exception.Message)"
        }

        [pscustomobject]@{
            SiteUrl      = $site
            Status       = $status
            Rows         = $rows
            CsvPath      = $csvPath
            FinishedAt   = (Get-Date -Format 'o')
        } | Export-Csv -LiteralPath $manifestPath -Append -NoTypeInformation -Encoding UTF8
    }
}
finally {
    # --- Merge whatever completed into one combined CSV (best effort). ----------------------------
    try {
        $combinedFolder = Join-Path $runFolder '_combined'
        if (-not (Test-Path -LiteralPath $combinedFolder)) {
            New-Item -ItemType Directory -Path $combinedFolder -Force | Out-Null
        }
        $csvFiles = Get-ChildItem -LiteralPath $runFolder -Recurse -Filter 'UserAccessReport_*.csv' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]_combined[\\/]' }
        if ($csvFiles) {
            $combined = foreach ($f in $csvFiles) { Import-Csv -LiteralPath $f.FullName }
            $combinedPath = Join-Path $combinedFolder "UserAccessReport_${safeUser}_combined.csv"
            if ($combined) {
                $combined | Export-Csv -LiteralPath $combinedPath -NoTypeInformation -Encoding UTF8
                Write-Host ""
                Write-Host "Combined CSV: $combinedPath  ($(@($combined).Count) rows from $($csvFiles.Count) site file(s))" -ForegroundColor Green
            }
        }
        else {
            Write-Host "No per-site CSVs found to merge yet." -ForegroundColor Yellow
        }
        Write-Host "Manifest    : $manifestPath"
        Write-Host "Log         : $logPath"
    }
    catch {
        Write-Warning "Merge step failed: $($_.Exception.Message)"
    }

    try { Disconnect-SPOPermissions } catch { }
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
