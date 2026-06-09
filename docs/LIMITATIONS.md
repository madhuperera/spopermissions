# Limitations & accuracy notes

This solution reports SharePoint Online locations a user can access for **audit, discovery, and client
reporting**. It is a **high-confidence approximation**, not a guaranteed evaluation of *effective* access.
Read this before relying on the output for high-stakes decisions. A condensed version of this page is
written into the `*.NOTES.txt` file beside every report so the caveats travel with the data.

## 1. Assigned vs. effective vs. inherited permissions

There is a real difference between these, and it matters:

- **Assigned permissions** – an explicit role assignment on an object (user/group → permission level).
- **Inherited permissions** – permissions an object receives from its parent because inheritance is intact.
- **Effective permissions** – what a user can *actually* do after combining all assignments, group
  memberships, sharing, and any platform-level overrides.

**What this tool computes:** access derived from **role assignments + group membership** (SharePoint groups
and transitive Entra ID groups). This closely approximates effective access but does **not** call a
per-object effective-permissions API (e.g. CSOM `GetUserEffectivePermissions`) for every securable, because
doing so tenant-wide is prohibitively slow and throttle-prone.

**Consequences:**

- The system **"Limited Access"** role is **excluded by default**. SharePoint grants it automatically so a
  user can traverse to a child item they *do* have rights to; on its own it is not meaningful access and
  would otherwise create large amounts of noise.
- Platform-level factors that can **reduce** real access are **not** evaluated: access restriction /
  conditional access policies, information-barrier segments, restricted-access control policies, locked or
  read-only sites, retention/legal-hold effects, etc. The report may therefore show access that a policy
  blocks in practice.

## 2. Inherited vs. unique (why not every file is listed)

A file, folder, or list appears in the report **only where permission inheritance is broken** (the object
has *unique* role assignments). Objects that **inherit** are intentionally **not** listed individually —
they are represented by the nearest parent that owns its permissions (the site or library row).

- A **site (web) row** implies access to everything beneath it that still inherits.
- A **library/list row** implies access to all items in it that still inherit.
- A **file/folder row** appears only when that specific item has unique permissions.

This matches the SharePoint security model and keeps tenant-scale crawls tractable. The trade-off: to see a
specific inherited file, look at the parent row that grants the access.

## 3. Sharing links

When content is shared, SharePoint creates a hidden `SharingLinks.<guid>...` group on the item and breaks
inheritance. This tool detects access through those groups during the normal crawl (no separate, slower
pass), and labels it `AccessType = SharingLink`:

- **"Specific people" links** – matched when the user is an **explicit target** of the link.
- **"Organization" / "Anyone" links** – grant access **without naming the user**. These are reported as
  **potential (broad) access** and only when broad access is included (the default; disable with
  `-ExcludeBroadAccess`). "Anyone" links also grant anonymous/external access.

Known gaps: sharing-link metadata exposed through PnP/Graph can be incomplete, and some externally-shared
or expired links may be under- or over-represented. Treat the sharing-link rows as indicative.

## 4. Group nesting & dynamic groups

Indirect access through Entra ID security / Microsoft 365 groups uses the user's **transitive** group
membership from Microsoft Graph (`transitiveMemberOf`). This depends on the consented Graph permissions and
on Graph's own evaluation:

- Deeply nested groups are covered by `transitiveMemberOf`, but **dynamic-membership** groups reflect
  Graph's current calculation, which can lag.
- SharePoint groups are expanded live via `Get-PnPGroupMember`; nested Entra groups inside a SharePoint
  group are matched against the same transitive membership set.

## 5. Scope, freshness & permissions to run

- Results reflect tenant state **at crawl time**.
- Enumerating the whole tenant requires the **SharePoint Administrator** role; reading content permissions
  across all sites requires that the admin can access those sites. Sites that cannot be read are reported as
  **skipped/errored** in the summary rather than silently omitted.
- Very large tenants/libraries: use `-Depth List` for faster discovery, scope with `-SiteUrl`, or cap with
  `-MaxItemsPerList`.

## 6. Authentication model

Interactive admin sign-in via **your own Entra ID app registration** (required by PnP PowerShell since
September 2024). No unattended/scheduled runs in this version — that would require certificate-based
app-only auth (a possible future enhancement).

## 7. Support

Built on **PnP PowerShell** (community, .NET Foundation) and Microsoft Graph. PnP PowerShell is **not** a
Microsoft-supported module and carries **no SLA**.

## Conclusion

**Full effective access cannot be guaranteed in all scenarios.** This report is a strong, defensible
approximation suitable for audit and discovery. For high-stakes access decisions (e.g. confirming a user
*cannot* reach specific content), corroborate findings — for example with the SharePoint admin center's
"check permissions" feature on the specific object, or the native **SharePoint Advanced Management** "site
permissions for users" report where licensed.
