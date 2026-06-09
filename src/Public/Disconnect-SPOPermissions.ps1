function Disconnect-SPOPermissions {
    <#
    .SYNOPSIS
        Disconnects the current PnP PowerShell session and clears module connection context.

    .EXAMPLE
        Disconnect-SPOPermissions
    #>
    [CmdletBinding()]
    param()

    try {
        if (Get-Command -Name Disconnect-PnPOnline -ErrorAction SilentlyContinue) {
            Disconnect-PnPOnline -ErrorAction SilentlyContinue
        }
    }
    finally {
        $script:SPOPermissionsContext = $null
        Write-Verbose 'Disconnected and cleared SPOPermissions context.'
    }
}
