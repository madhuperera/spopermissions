# SPOPermissions

Report **SharePoint Online access for a specific user account** — the sites, document libraries, folders,
and files a given UPN can reach — for **audit, discovery, and client reporting**.

Given a username/UPN, the solution crawls SharePoint and produces a CSV of every location the user has
access to, how that access is granted (directly, via a SharePoint group, via an Entra ID group, or via a
sharing link), and the permission level — plus a run summary and a limitations notes file.

> ⚠️ **Read [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) first.** This is a high-confidence *approximation*
> of access (assigned permissions + group membership), **not** a guaranteed evaluation of *effective*
> access. Full effective access cannot be guaranteed in all scenarios. The same caveats are written into a
> `*.NOTES.txt` file beside every report.

## Why this approach (options considered)

Per-user SharePoint permission reporting can be done several ways. Research (current as of 2026) compared:

| Approach | Supported by | Per-user granularity | Notes |
|---|---|---|---|
| **PnP PowerShell crawl** (this tool) | Community (.NET Foundation), no MS SLA | Site → library → folder → file | Only option reaching file/folder level on **any** tenant with no paid add-on |
| **SharePoint Advanced Management (SAM)** — `Start-SPODataAccessGovernanceInsight -ReportEntity PermissionsReport` → "site permissions for users" | Microsoft | Site level | **Requires the paid SAM license**; tenant-wide; first run can take up to 5 days. Best native option **if licensed** |
| **Microsoft Graph PowerShell** (`Get-MgSitePermission`, driveItem permissions) | Microsoft | Limited | Cannot list subsite permissions; weak for the full SharePoint role-assignment model |
| **SPO Management Shell** (`Get-SPOSite` / `Get-SPOUser`) | Microsoft | Site-collection only | Too coarse for file/folder reporting |

This tool uses the **PnP crawl** because it works on any tenant and reaches file/folder granularity. If the
target tenant **is** licensed for SAM, also consider the native report — see "Native alternative" below.

## Prerequisites

- **PowerShell 7.2+**
- **PnP.PowerShell** module: `Install-Module PnP.PowerShell -Scope CurrentUser`
- An account with the **SharePoint Administrator** role (needed for tenant-wide enumeration and to read
  permissions across site collections).
- **Your own Entra ID app registration** (PnP no longer ships a shared sign-in app since Sept 2024).

### One-time setup: register the Entra ID app

You need an app registration that PnP PowerShell signs into. Easiest is PnP's helper:

```powershell
Register-PnPEntraIDAppForInteractiveLogin -ApplicationName "SPOPermissions-Reporting" -Tenant contoso.onmicrosoft.com -Interactive
```

This creates the app and prompts for admin consent. Note the **ClientId** it returns.

If creating the app manually in the Entra admin center, grant these **delegated** permissions and grant
admin consent:

- **SharePoint** → `AllSites.FullControl` (read permissions across all sites)
- **Microsoft Graph** → `User.Read.All`, `GroupMember.Read.All` (resolve the user + transitive group
  membership), and `Sites.FullControl.All` if you intend to also read site-level Graph permissions.
- Add a public client / native redirect URI (`http://localhost`) for the interactive flow.

> The signed-in **user** still needs the SharePoint Administrator role; the app delegated permissions
> determine the API surface, the user's roles determine what data is actually returned.

## Install / import

```powershell
git clone <this-repo>
cd SPOPermissions
Import-Module ./src/SPOPermissions.psd1 -Force
```

## Usage

### Quickest path — the wrapper script

```powershell
# Copy and fill in defaults (Url + ClientId)
Copy-Item ./config/settings.sample.json ./config/settings.json

# Single site, full depth (files/folders)
./scripts/Run-UserAccessReport.ps1 -UserPrincipalName jane.doe@contoso.com `
    -SiteUrl https://contoso.sharepoint.com/sites/Finance

# Whole tenant, libraries level (much faster discovery)
./scripts/Run-UserAccessReport.ps1 -UserPrincipalName jane.doe@contoso.com -Depth List
```

### Using the module directly

```powershell
Import-Module ./src/SPOPermissions.psd1 -Force

Connect-SPOPermissions -Url https://contoso.sharepoint.com -ClientId '<your-app-client-id>'

Get-SPOUserAccessReport -UserPrincipalName jane.doe@contoso.com `
    -SiteUrl https://contoso.sharepoint.com/sites/Finance `
    -Depth File -OutputFolder ./reports

Disconnect-SPOPermissions
```

### Key parameters (`Get-SPOUserAccessReport`)

| Parameter | Purpose |
|---|---|
| `-UserPrincipalName` | UPN to report on (required) |
| `-SiteUrl` | One or more site URLs. Omit to crawl **all** tenant sites |
| `-Depth` | `Site` \| `List` \| `File` (default `File`) |
| `-OutputFolder` | Output location (default `./reports`) |
| `-MaxItemsPerList` | Cap items inspected per list at `File` depth (0 = no cap) |
| `-IncludeOneDrive` | Include personal OneDrive sites in tenant enumeration |
| `-IncludeHiddenLists` | Include hidden lists/libraries |
| `-ExcludeBroadAccess` | Exclude Everyone / Org / Anyone (broad/potential) access |
| `-IncludeLimitedAccess` | Include the system "Limited Access" traversal role (off by default; it's noise) |
| `-PassThru` | Also return records to the pipeline |

> **Performance:** `-Depth File` inspects every item with unique permissions, which is **one server
> round-trip per item** and loads a list's items into memory. On large libraries this is slow and
> throttle-prone. For whole-tenant runs prefer `-Depth List` (or `Site`) for discovery, then re-run
> `-Depth File` against the specific sites of interest, and use `-MaxItemsPerList` as a guard.

## Output

Three timestamped files per run in the output folder:

- `UserAccessReport_<upn>_<timestamp>.csv` — one row per access location. Columns:
  `SiteUrl, ScopeType, Title, ObjectUrl, AccessType, AccessVia, Roles, InheritanceBroken, Notes`
  - `ScopeType`: `Web` | `List` | `Folder` | `File` | `ListItem`
  - `AccessType`: `RoleAssignment` | `SharingLink`
  - `AccessVia`: `Direct`, `SPGroup:<name>`, `EntraGroup:<name>`, `SharingLink:<Specific|Organization|Anyone>`, `Everyone`, `EveryoneExceptExternal`
- `…summary.txt` — run metadata, counts by scope/site, sites skipped/errored
- `…NOTES.txt` — the limitations (always read these)

## How it works

1. **Resolve identity** — UPN → Entra object id + transitive group membership (Microsoft Graph via
   `Invoke-PnPGraphMethod`).
2. **Scope** — explicit `-SiteUrl` list, or all sites via `Get-PnPTenantSite`.
3. **Crawl** — for each site walk web → lists → (optionally) folders/files, evaluating only objects with
   **unique** permissions (broken inheritance). Match the user directly and through SharePoint/Entra groups;
   classify `SharingLinks.*` groups as sharing links.
4. **Report** — write CSV + summary + notes.

## Native alternative (if licensed for SAM)

If the tenant has **SharePoint Advanced Management**, the Microsoft-native "site permissions for users"
report lists sites a user can access:

```powershell
Start-SPODataAccessGovernanceInsight -ReportEntity PermissionsReport -ReportType Snapshot `
    -Workload SharePoint -Name "UserReport" -UserPrincipalNames "jane.doe@contoso.com"
Get-SPODataAccessGovernanceInsight -ReportEntity PermissionsReport      # get ReportID + status
Export-SPODataAccessGovernanceInsight -ReportID <guid> -DownloadPath ./reports
```

It is site-level (not file/folder), tenant-wide only, and refreshes on a delay — but it is Microsoft-supported.

## Testing

```powershell
Invoke-Pester ./tests
```

The tests cover the pure logic (claim parsing, principal matching, sharing-link classification, output
schema) with no live tenant or PnP connection required. See [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) for
a live smoke-test checklist.

## Disclaimer

Built on PnP PowerShell (community / .NET Foundation) and Microsoft Graph — **no Microsoft SLA**. Provided
as-is. Validate results before acting on them.
