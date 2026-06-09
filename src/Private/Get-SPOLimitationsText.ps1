function Get-SPOLimitationsText {
    <#
    .SYNOPSIS
        Returns the canonical, concise limitations/caveats text embedded in every report's notes file.

    .DESCRIPTION
        Keeping this in one place ensures the caveats that travel with each report stay consistent with
        docs/LIMITATIONS.md. See that file for the full discussion.
    #>
    [CmdletBinding()]
    param()

    @'
IMPORTANT - HOW TO READ THIS REPORT (limitations)

This report lists SharePoint Online locations where the specified user has access, derived from
SharePoint role assignments plus the user's group memberships. It is a high-confidence approximation,
not a guaranteed evaluation of effective access. Read these caveats before relying on it:

1. ASSIGNED vs EFFECTIVE
   Access is computed from role assignments + group membership, NOT from a per-object effective-access
   evaluation. It does not resolve every edge case (e.g. "Limited Access" traversal grants, access
   policies, conditional access, information-barrier segments). "Limited Access" is excluded by default.

2. INHERITED vs UNIQUE
   File/folder/list rows appear ONLY where permission inheritance is broken (the object has unique
   permissions). Locations that inherit are covered by the nearest parent row (site or library) and are
   not listed individually - by design and for performance. A site/library row therefore implies access
   to everything beneath it that still inherits.

3. SHARING LINKS
   Sharing links are detected via the hidden "SharingLinks.*" groups SharePoint creates on shared items.
   "Specific people" links are matched when the user is an explicit target. "Organization"/"Anyone"
   links grant access without naming the user; these are reported only as potential (broad) access and
   only when broad access is included (default). Some link metadata may be incomplete.

4. GROUP NESTING / DYNAMIC GROUPS
   Indirect access via Entra ID groups uses the user's transitive group membership from Microsoft Graph.
   Deeply nested or dynamic-membership groups depend on Graph data and consented permissions and may be
   incompletely expanded.

5. SCOPE & FRESHNESS
   Results reflect tenant state at crawl time. Sites the running admin cannot access are reported as
   skipped/errored in the summary. Large tenants may require scoped runs.

6. NO MICROSOFT SLA
   Built on PnP PowerShell (community / .NET Foundation), not a Microsoft-supported module.

CONCLUSION: Full effective access cannot be guaranteed in all scenarios. Use this report for audit and
discovery, and corroborate before making high-stakes access decisions.
'@
}
