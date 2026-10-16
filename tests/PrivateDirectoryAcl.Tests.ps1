param([switch]$NativeOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$modulePath = Join-Path $PSScriptRoot '../package/Backup.Windows.psm1'
function Assert-True($condition, [string]$message) { if (-not $condition) { throw "ASSERTION FAILED: $message" } }

if ($NativeOnly) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Native ACL test requires Windows, not emulation.' }
    Import-Module (Join-Path $PSScriptRoot '../package/Backup.Core.psm1') -Force -DisableNameChecking
    Import-Module $modulePath -Force -DisableNameChecking
    $path = Join-Path ([IO.Path]::GetTempPath()) ('ydb-private-acl-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($path) | Out-Null
    try {
        $before = Get-Acl -LiteralPath $path
        Protect-YdbPrivateDirectory -Path $path
        Protect-YdbPrivateDirectory -Path $path
        $after = Get-Acl -LiteralPath $path
        Assert-True $after.AreAccessRulesProtected 'Private folder must have protected DACL'
        Assert-True ($before.Owner -eq $after.Owner) 'Owner must not be changed'
        $sidType = [Security.Principal.SecurityIdentifier]
        $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $rules = @($after.GetAccessRules($true, $true, $sidType))
        Assert-True ($rules.Count -eq 2) 'Exactly current user and SYSTEM rules'
        foreach ($rule in $rules) {
            Assert-True ($rule.IdentityReference.Value -in @($userSid, 'S-1-5-18')) 'No broad principal may receive access'
            Assert-True ($rule.AccessControlType -eq 'Allow') 'Required access must be allowed'
            Assert-True (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) 'Full control required for private files'
            Assert-True ($rule.InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit') 'Private access must inherit to files and folders'
        }
        $child = Join-Path $path 'non-secret-fixture.txt'
        [IO.File]::WriteAllText($child, 'SYNTHETIC NON-SECRET FIXTURE')
        $childRules = @((Get-Acl -LiteralPath $child).GetAccessRules($true, $true, $sidType))
        Assert-True ($childRules.Count -eq 2) 'New private files must inherit only two access rules'
        Assert-True (@($childRules | Where-Object { -not $_.IsInherited }).Count -eq 0) 'Child rules must be inherited'
        Write-Host 'PASS: NATIVE Windows ACL, repeat startup, unchanged owner and restricted child inheritance'
    } finally { Remove-Item -LiteralPath $path -Recurse -Force }
    return
}

# Linux cannot construct WindowsIdentity/DirectorySecurity. Execute the actual
# production function with these OS boundaries replaced, not the ACL algorithm.
# The separate -NativeOnly test above exercises the unmodified function on Windows.
class YdbAclFixture {
    [bool]$OwnerModified = $false
    [bool]$Protected = $false
    [bool]$PreserveInherited = $true
    [System.Collections.ArrayList]$Rules = [System.Collections.ArrayList]::new()
    [void]SetOwner([object]$owner) { $this.OwnerModified = $true }
    [void]SetAccessRuleProtection([bool]$protect, [bool]$preserve) { $this.Protected = $protect; $this.PreserveInherited = $preserve }
    [void]AddAccessRule([object]$rule) { [void]$this.Rules.Add($rule) }
}
class YdbDirectoryFixture {
    [int]$PersistCount = 0
    [bool]$DenyWrite = $false
    [void]SetAccessControl([object]$acl) {
        if ($this.DenyWrite) { throw 'SYNTHETIC access denied: DACL cannot be protected' }
        if ($acl.OwnerModified) { throw 'Owner modification must not be requested' }
        if (-not $acl.Protected -or $acl.PreserveInherited -or $acl.Rules.Count -ne 2) { throw 'Private DACL is incomplete' }
        $this.PersistCount++
    }
}
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'Production module must parse'
$functionAst = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Protect-YdbPrivateDirectory'}, $true)
Assert-True ($null -ne $functionAst) 'Missing private directory protection'
$text = $functionAst.Extent.Text.Replace('[Security.Principal.WindowsIdentity]::GetCurrent()', "([pscustomobject]@{ User = 'S-1-5-21-100-200-300-1001' })")
. ([scriptblock]::Create($text))
$script:aclFixture = $null
$script:directoryFixture = [YdbDirectoryFixture]::new()
function New-Object {
    param([string]$TypeName, [object[]]$ArgumentList)
    switch ($TypeName) {
        'Security.AccessControl.DirectorySecurity' { $script:aclFixture = [YdbAclFixture]::new(); return $script:aclFixture }
        'Security.Principal.SecurityIdentifier' { return [string]$ArgumentList[0] }
        'Security.AccessControl.FileSystemAccessRule' { return [pscustomobject]@{Sid=[string]$ArgumentList[0]; Rights=[string]$ArgumentList[1]; Inherit=$ArgumentList[2]} }
        'IO.DirectoryInfo' { return $script:directoryFixture }
        default { throw "Unexpected OS dependency in ACL fixture: $TypeName" }
    }
}
function Assert-YdbNoReparsePoint { param([string]$Path) Assert-True ([IO.Directory]::Exists($Path)) 'Private directory must exist before ACL protection' }
function Set-Acl { param($LiteralPath, $AclObject, $ErrorAction) throw "The process does not possess the 'SeSecurityPrivilege' privilege which is required for this operation." }
$root = Join-Path ([IO.Path]::GetTempPath()) ('ydb-acl-seam-' + [Guid]::NewGuid().ToString('N'))
try {
    Protect-YdbPrivateDirectory -Path $root
    Protect-YdbPrivateDirectory -Path $root
    Assert-True ($script:directoryFixture.PersistCount -eq 2) 'Both startups must persist only modified DACL sections'
    Assert-True (-not $script:aclFixture.OwnerModified) 'Owner changes require unnecessary privileges'
    $sids = @($script:aclFixture.Rules | ForEach-Object { $_.Sid })
    Assert-True ($sids.Count -eq 2 -and $sids -contains 'S-1-5-18' -and $sids -contains 'S-1-5-21-100-200-300-1001') 'Only current user and SYSTEM'
    foreach ($rule in $script:aclFixture.Rules) { Assert-True ($rule.Rights -eq 'FullControl') 'Do not weaken token-directory access control' }
    $script:directoryFixture.DenyWrite = $true
    $rejected = $false
    try { Protect-YdbPrivateDirectory -Path $root } catch { $rejected = $_.Exception.Message -like '*DACL cannot be protected*' }
    Assert-True $rejected 'Fail closed if ACL persistence fails; do not silently continue with exposed credentials'
    Write-Host 'PASS: OS-SEAM EMULATION: no SeSecurityPrivilege path, private DACL, repeat startup and fail-closed persistence'
    Write-Host 'NOT RUN: native Windows ACL test (run this script with -NativeOnly on Windows)'
} finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) } }
