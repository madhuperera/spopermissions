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
- **Roles on the target tenant** (the *signed-in user*, not the app, must hold these):
  - **SharePoint Administrator** — needed at *report time* for tenant-wide enumeration and to read
    permissions across site collections.
  - **Application Administrator**, **Cloud Application Administrator**, or **Global Administrator** —
    needed once at *setup time* to register the Entra ID app **and grant it admin consent**. (An
    *Application Developer* can register an app but **cannot** grant tenant-wide consent, so the setup
    below will half-complete.)
- **Your own Entra ID app registration** (PnP no longer ships a shared sign-in app since Sept 2024).
  Step 1 below creates it.

## Setup

Do steps 1–2 **once** per tenant. Step 3 onward is the normal per-run flow.

### Step 1 — Register the Entra ID app

PnP PowerShell needs an Entra ID app registration to sign into. The `Register-PnPEntraIDAppForInteractiveLogin`
cmdlet creates and configures one for you.

> **Where do you run this?** In a plain **PowerShell 7** session on your own machine — **not** inside an
> existing PnP connection. You do **not** run `Connect-PnPOnline` first. The cmdlet launches its **own**
> browser sign-in to do the registration. So the only prerequisite is that the PnP module is installed.

```powershell
# 1. Open a fresh PowerShell 7 terminal and load the module
Import-Module PnP.PowerShell

# 2. Create the app. Replace contoso.onmicrosoft.com with YOUR tenant's primary domain
#    (find it at https://entra.microsoft.com -> Overview -> "Primary domain").
Register-PnPEntraIDAppForInteractiveLogin `
    -ApplicationName "SPOPermissions-Reporting" `
    -Tenant contoso.onmicrosoft.com `
    -SharePointDelegatePermissions "AllSites.FullControl" `
    -GraphDelegatePermissions "User.Read.All","GroupMember.Read.All"
```

> **No `-Interactive` switch.** Interactive browser sign-in is the **default** behaviour — there is no
> `-Interactive` parameter (passing one throws *"A parameter cannot be found that matches parameter name
> 'Interactive'"*). If your machine can't open a browser, add **`-DeviceLogin`** instead to use the device-code
> flow (it prints a code to enter at https://microsoft.com/devicelogin).

What happens when you run it:

1. A **browser window opens** (or, with `-DeviceLogin`, a code to enter) — sign in as an admin who can
   register apps **and** consent (see Prerequisites). This first sign-in *creates* the app.
2. The cmdlet waits ~60 seconds for the registration to propagate.
3. A **second browser prompt** appears showing the requested permissions — click **Accept** to grant
   tenant-wide admin consent.
4. The cmdlet prints the new **ClientId** (a GUID). **Copy it** — you need it for every run (Step 3).

The `*DelegatePermissions` above are what this tool actually uses: `AllSites.FullControl` to read
permissions across SharePoint sites, and `User.Read.All` + `GroupMember.Read.All` to resolve the target
user and their transitive group membership. Add Graph `Sites.FullControl.All` only if you also intend to
read site-level Graph permissions.

> **Why these are *delegated* permissions:** the tool acts **as the signed-in admin**, so the app's
> delegated scopes set the API surface, while the admin's own roles (SharePoint Administrator) decide what
> data actually comes back. That is why the user running the report still needs SharePoint Administrator —
> the app permissions alone are not enough.

### Step 1 (alternative) — Register the app manually

If you'd rather not use the cmdlet, create the app in the **Entra admin center**
(https://entra.microsoft.com → **App registrations** → **New registration**):

- **Supported account types:** single tenant.
- **Authentication →** add a **Mobile and desktop applications** (public client) platform with redirect
  URI `http://localhost` — required for the interactive sign-in flow.
- **API permissions →** add these **delegated** permissions, then **Grant admin consent**:
  - **SharePoint** → `AllSites.FullControl`
  - **Microsoft Graph** → `User.Read.All`, `GroupMember.Read.All` (and `Sites.FullControl.All` only if you
    need site-level Graph permissions).
- Copy the **Application (client) ID** from the app's **Overview** page — that is the ClientId for Step 3.

### Step 2 — Confirm your roles

Make sure the account you'll run reports with holds the **SharePoint Administrator** role (Microsoft 365
admin center → **Roles**, or Entra ID → **Roles and administrators**). Without it the crawl connects but
returns little or no permission data.

### Step 3 — Install / import this tool

```powershell
git clone <this-repo>
cd SPOPermissions
Import-Module ./src/SPOPermissions.psd1 -Force
```

You'll supply the **ClientId** from Step 1 either in `config/settings.json` or via the `-ClientId`
parameter when you connect (see Usage).

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
| `-MaxItemsPerList` | Cap items inspected per list at `File` depth (0 = no cap). A flat **count** cap, **not** a depth control |
| `-MaxFolderDepth` | Limit folder levels descended per library at `File` depth (`-1` = unlimited). See below |
| `-IncludeOneDrive` | Include personal OneDrive sites in tenant enumeration |
| `-IncludeHiddenLists` | Include hidden lists/libraries |
| `-ExcludeBroadAccess` | Exclude Everyone / Org / Anyone (broad/potential) access |
| `-IncludeLimitedAccess` | Include the system "Limited Access" traversal role (off by default; it's noise) |
| `-PassThru` | Also return records to the pipeline |

> **Performance:** `-Depth File` inspects every item with unique permissions, which is **one server
> round-trip per item** and loads a list's items into memory. On large libraries this is slow and
> throttle-prone. For whole-tenant runs prefer `-Depth List` (or `Site`) for discovery, then re-run
> `-Depth File` against the specific sites of interest, and use `-MaxFolderDepth` / `-MaxItemsPerList`
> as guards.

### Limiting how deep the crawl goes (`-MaxFolderDepth` vs `-MaxItemsPerList`)

These two guards are different and easy to confuse:

- **`-MaxFolderDepth N`** is a **true folder-depth limit**: how many folder levels below each library
  root the `File` crawl descends. Depth is measured by an item's *containing folder*:
  - `0` — library **root only**: root files and top-level folders are *listed* (you see `Folder1`
    and its permissions) but **not entered**.
  - `1` — **one folder level inside**: descend into the top-level folders (`Folder1`) and inspect
    their direct contents (including that `Folder2` exists), but do **not** enter `Folder2`.
  - `N` — descend `N` folder levels below the root. `-1` (default) = unlimited.
- **`-MaxItemsPerList N`** is a **flat count cap**: it stops after N items in a single flat,
  id-ordered stream (files *and* folders, all nesting), so it **cannot** express depth — a small cap
  can stop inside one deep subfolder and never reach a sibling top-level folder. Use it only as a
  runaway guard.

Example — scan a library only to its first folder level (e.g. `…/Documents/Folder1`):

```powershell
Get-SPOUserAccessReport -UserPrincipalName jane.doe@contoso.com `
    -SiteUrl https://contoso.sharepoint.com/sites/Finance -Depth File -MaxFolderDepth 1
```

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
