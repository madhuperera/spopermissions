# SPOPermissions.psm1
# Root module: dot-sources all Public/Private function files and exports the public surface.

$ErrorActionPreference = 'Stop'

$public  = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue )
$private = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue )

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to import function file $($file.FullName): $_"
    }
}

Export-ModuleMember -Function $public.BaseName
