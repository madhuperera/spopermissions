function Write-SPOAccessOutput {
    <#
    .SYNOPSIS
        Writes the access report to disk: a CSV of records, a run summary, and a limitations notes file.

    .DESCRIPTION
        Produces three files in -OutputFolder, all sharing a timestamped base name so the caveats and
        summary always travel with the data:
          <base>.csv           - one row per access location
          <base>.summary.txt   - run metadata + counts by scope/site
          <base>.NOTES.txt     - limitations (from Get-SPOLimitationsText)

    .OUTPUTS
        PSCustomObject with CsvPath, SummaryPath, NotesPath, RecordCount.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Records,
        [Parameter(Mandatory)] [string]$OutputFolder,
        [Parameter(Mandatory)] [string]$UserPrincipalName,
        [Parameter(Mandatory)] [hashtable]$RunMeta
    )

    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }

    $safeUser  = ($UserPrincipalName -replace '[^a-zA-Z0-9._-]', '_')
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $base      = Join-Path $OutputFolder "UserAccessReport_${safeUser}_${timestamp}"

    $csvPath     = "$base.csv"
    $summaryPath = "$base.summary.txt"
    $notesPath   = "$base.NOTES.txt"

    # CSV (always create a file, even with zero rows, so the run is auditable).
    if ($Records.Count -gt 0) {
        $Records | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    }
    else {
        # Derive the header from the record factory so it never drifts from the real schema.
        # Values are irrelevant here - we only read the property names.
        $header = (New-SPOAccessRecord -SiteUrl '-' -ScopeType 'Web').PSObject.Properties.Name -join ','
        $header | Set-Content -LiteralPath $csvPath -Encoding UTF8
    }

    # Summary
    $byScope = $Records | Group-Object ScopeType | Sort-Object Name |
        ForEach-Object { "    {0,-10} {1}" -f $_.Name, $_.Count }
    $bySite = $Records | Group-Object SiteUrl | Sort-Object Count -Descending |
        Select-Object -First 50 |
        ForEach-Object { "    {0,5}  {1}" -f $_.Count, $_.Name }
    $sharingCount = @($Records | Where-Object AccessType -eq 'SharingLink').Count

    $summary = @()
    $summary += '=== SharePoint Online User Access Report - Summary ==='
    $summary += ''
    $summary += "User (UPN)         : $UserPrincipalName"
    $summary += "Display name       : $($RunMeta.DisplayName)"
    $summary += "Generated          : $(Get-Date -Format 'u')"
    $summary += "Crawl depth        : $($RunMeta.Depth)"
    $summary += "Scope              : $($RunMeta.ScopeDescription)"
    $summary += "Run duration       : $($RunMeta.Duration)"
    $summary += ''
    $summary += "Sites in scope     : $($RunMeta.SitesTotal)"
    $summary += "Sites scanned OK   : $($RunMeta.SitesScanned)"
    $summary += "Sites skipped/error: $($RunMeta.SitesError)"
    $summary += ''
    $summary += "Total access rows   : $($Records.Count)"
    $summary += "  via sharing links : $sharingCount"
    $summary += ''
    $summary += 'Access rows by scope:'
    $summary += ($byScope -join [Environment]::NewLine)
    $summary += ''
    $summary += 'Top sites by access rows:'
    $summary += ($bySite -join [Environment]::NewLine)
    if ($RunMeta.Errors -and $RunMeta.Errors.Count -gt 0) {
        $summary += ''
        $summary += 'Sites skipped / errored:'
        $summary += ($RunMeta.Errors | ForEach-Object { "    $_" })
    }
    $summary += ''
    $summary += 'See the accompanying .NOTES.txt for important limitations.'
    ($summary -join [Environment]::NewLine) | Set-Content -LiteralPath $summaryPath -Encoding UTF8

    # Notes / limitations
    Get-SPOLimitationsText | Set-Content -LiteralPath $notesPath -Encoding UTF8

    [pscustomobject]@{
        CsvPath     = $csvPath
        SummaryPath = $summaryPath
        NotesPath   = $notesPath
        RecordCount = $Records.Count
    }
}
