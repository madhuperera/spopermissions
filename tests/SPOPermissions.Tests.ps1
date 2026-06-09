#requires -Modules Pester

# Unit tests for SPOPermissions pure logic. No live tenant or PnP connection required.
# Run: Invoke-Pester ./tests

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:ManifestPath = Join-Path $repoRoot 'src/SPOPermissions.psd1'

    # Dot-source the individual function files so we can exercise PRIVATE (non-exported) helpers.
    Get-ChildItem -Path (Join-Path $repoRoot 'src/Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    Get-ChildItem -Path (Join-Path $repoRoot 'src/Public')  -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function New-TestIdentity {
        param([string[]]$DirectKeys, [string[]]$GroupIds)
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($g in $GroupIds) { [void]$set.Add($g) }
        [pscustomobject]@{
            Upn             = ($DirectKeys | Select-Object -First 1)
            DirectMatchKeys = ($DirectKeys | ForEach-Object { $_.ToLowerInvariant() })
            GroupObjectIds  = $set
        }
    }
}

Describe 'Module manifest' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }
    It 'exports the public functions' {
        $m = Test-ModuleManifest -Path $script:ManifestPath
        $m.ExportedFunctions.Keys | Should -Contain 'Connect-SPOPermissions'
        $m.ExportedFunctions.Keys | Should -Contain 'Get-SPOUserAccessReport'
        $m.ExportedFunctions.Keys | Should -Contain 'Disconnect-SPOPermissions'
    }
}

Describe 'Get-SPOClaimObjectId' {
    It 'classifies a user membership claim' {
        (Get-SPOClaimObjectId -LoginName 'i:0#.f|membership|jane@contoso.com').Kind | Should -Be 'User'
    }
    It 'extracts the object id from an Entra security group claim' {
        $r = Get-SPOClaimObjectId -LoginName 'c:0t.c|tenant|11111111-2222-3333-4444-555555555555'
        $r.Kind     | Should -Be 'EntraGroup'
        $r.ObjectId | Should -Be '11111111-2222-3333-4444-555555555555'
    }
    It 'extracts the object id from an M365 group claim' {
        $r = Get-SPOClaimObjectId -LoginName 'c:0o.c|federateddirectoryclaimprovider|11111111-2222-3333-4444-555555555555_o'
        $r.Kind     | Should -Be 'M365Group'
        $r.ObjectId | Should -Be '11111111-2222-3333-4444-555555555555'
    }
    It 'recognises Everyone except external users' {
        (Get-SPOClaimObjectId -LoginName 'c:0-.f|rolemanager|spo-grid-all-users/72f988bf').Kind | Should -Be 'EveryoneExceptExternal'
    }
    It 'recognises Everyone' {
        (Get-SPOClaimObjectId -LoginName 'c:0(.s|true').Kind | Should -Be 'Everyone'
    }
    It 'returns Unknown for an unrecognised claim' {
        (Get-SPOClaimObjectId -LoginName 'something-weird').Kind | Should -Be 'Unknown'
    }
}

Describe 'Test-SPOMemberGrantsUser' {
    BeforeAll {
        $script:identity = New-TestIdentity -DirectKeys @('jane@contoso.com') -GroupIds @('aaaaaaaa-1111-2222-3333-444444444444')
    }

    It 'matches a direct user by email' {
        $member = [pscustomobject]@{ LoginName = 'i:0#.f|membership|jane@contoso.com'; Email = 'jane@contoso.com'; PrincipalType = 'User'; Title = 'Jane' }
        Test-SPOMemberGrantsUser -Member $member -Identity $script:identity | Should -Be 'Direct'
    }

    It 'matches an Entra group the user belongs to' {
        $member = [pscustomobject]@{ LoginName = 'c:0t.c|tenant|aaaaaaaa-1111-2222-3333-444444444444'; PrincipalType = 'SecurityGroup'; Title = 'Finance-Readers' }
        Test-SPOMemberGrantsUser -Member $member -Identity $script:identity | Should -Be 'EntraGroup:Finance-Readers'
    }

    It 'does not match an Entra group the user is not in' {
        $member = [pscustomobject]@{ LoginName = 'c:0t.c|tenant|ffffffff-9999-9999-9999-999999999999'; PrincipalType = 'SecurityGroup'; Title = 'Other' }
        Test-SPOMemberGrantsUser -Member $member -Identity $script:identity | Should -BeNullOrEmpty
    }

    It 'returns Everyone for a broad claim when broad claims are included' {
        $member = [pscustomobject]@{ LoginName = 'c:0(.s|true'; PrincipalType = 'SecurityGroup'; Title = 'Everyone' }
        Test-SPOMemberGrantsUser -Member $member -Identity $script:identity -IncludeBroadClaims $true | Should -Be 'Everyone'
    }

    It 'suppresses broad claims when excluded' {
        $member = [pscustomobject]@{ LoginName = 'c:0(.s|true'; PrincipalType = 'SecurityGroup'; Title = 'Everyone' }
        Test-SPOMemberGrantsUser -Member $member -Identity $script:identity -IncludeBroadClaims $false | Should -BeNullOrEmpty
    }
}

Describe 'Get-SPOSharingLinkScope' {
    It 'classifies anonymous links as Anyone' {
        Get-SPOSharingLinkScope -Name 'SharingLinks.guid.AnonymousEdit.guid' | Should -Be 'Anyone'
    }
    It 'classifies organization links' {
        Get-SPOSharingLinkScope -Name 'SharingLinks.guid.OrganizationView.guid' | Should -Be 'Organization'
    }
    It 'classifies flexible/specific links' {
        Get-SPOSharingLinkScope -Name 'SharingLinks.guid.Flexible.guid' | Should -Be 'Specific'
    }
}

Describe 'New-SPOAccessRecord' {
    It 'produces the documented schema' {
        $r = New-SPOAccessRecord -SiteUrl 'https://x' -ScopeType 'File' -Title 'a.docx' -ObjectUrl '/sites/x/a.docx' -AccessVia 'Direct' -Roles 'Edit' -AccessType 'RoleAssignment' -InheritanceBroken $true
        $r.PSObject.Properties.Name | Should -Be @('SiteUrl', 'ScopeType', 'Title', 'ObjectUrl', 'AccessType', 'AccessVia', 'Roles', 'InheritanceBroken', 'Notes')
        $r.ScopeType  | Should -Be 'File'
        $r.AccessType | Should -Be 'RoleAssignment'
    }
    It 'rejects an invalid ScopeType' {
        { New-SPOAccessRecord -SiteUrl 'https://x' -ScopeType 'Bogus' } | Should -Throw
    }
}

Describe 'Write-SPOAccessOutput' {
    It 'writes a header-only CSV (matching the schema) when there are no records' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("spoperm_" + [guid]::NewGuid())
        try {
            $meta = @{ DisplayName = 'X'; Depth = 'File'; ScopeDescription = '1 site'; Duration = '0'; SitesTotal = 1; SitesScanned = 1; SitesError = 0; Errors = @() }
            $out = Write-SPOAccessOutput -Records @() -OutputFolder $tmp -UserPrincipalName 'jane@contoso.com' -RunMeta $meta
            $out.RecordCount | Should -Be 0
            Test-Path $out.CsvPath   | Should -BeTrue
            Test-Path $out.NotesPath | Should -BeTrue
            $expected = (New-SPOAccessRecord -SiteUrl '-' -ScopeType 'Web').PSObject.Properties.Name -join ','
            (Get-Content -LiteralPath $out.CsvPath -TotalCount 1) | Should -Be $expected
        }
        finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        }
    }
}
