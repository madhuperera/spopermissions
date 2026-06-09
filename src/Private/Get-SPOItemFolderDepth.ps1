function Get-SPOItemFolderDepth {
    <#
    .SYNOPSIS
        Returns how many folder levels below a list/library root a given item sits.

    .DESCRIPTION
        Pure path math used to enforce -MaxFolderDepth. The "containing folder depth" is the number
        of folder levels between the list root folder and the item's PARENT folder:

            <root>/report.docx          -> 0   (sits directly in the library root)
            <root>/Folder1              -> 0   (a top-level folder is itself a root-level item)
            <root>/Folder1/sub.docx     -> 1
            <root>/Folder1/Folder2      -> 1   (Folder2's parent, Folder1, is one level down)
            <root>/Folder1/Folder2/x    -> 2

        So -MaxFolderDepth N keeps items whose depth <= N:
          N = 0  lists root files and top-level folders WITHOUT descending into them.
          N = 1  descends one folder level (into Folder1) and inspects its direct contents.
          N = k  descends k folder levels below the root.

        The match is boundary-aware so a sibling library whose name merely shares a prefix
        (e.g. root '.../Documents' vs item '.../DocumentsArchive/a.docx') is NOT treated as inside.

    .PARAMETER ItemUrl
        Server-relative URL of the item (SharePoint FileRef),
        e.g. '/sites/Finance/Shared Documents/Folder1/a.docx'.

    .PARAMETER RootUrl
        Server-relative URL of the list/library root folder,
        e.g. '/sites/Finance/Shared Documents'.

    .OUTPUTS
        [int] containing-folder depth (>= 0), or -1 if the item is not under the given root
        (so callers can choose NOT to filter items they cannot classify).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ItemUrl,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$RootUrl
    )

    $item = ([string]$ItemUrl).Trim().TrimEnd('/')
    $root = ([string]$RootUrl).Trim().TrimEnd('/')
    if (-not $item -or -not $root) { return -1 }

    if (-not $item.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return -1 }

    # Ensure the match ends on a path boundary (avoid '/Documents' matching '/DocumentsArchive').
    $rest = $item.Substring($root.Length)
    if ($rest -and -not $rest.StartsWith('/')) { return -1 }

    $rel = $rest.Trim('/')
    if (-not $rel) { return 0 }
    return (($rel -split '/').Count - 1)
}
