$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../package/Backup.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../package/Backup.Windows.psm1') -Force -DisableNameChecking
function Assert-True($c,[string]$m) { if (-not $c) { throw "ASSERTION FAILED: $m" } }
$m = Get-Module Backup.Windows
& $m {
    $script:AskedClientId = $false
    function script:Read-Host {
        param([string]$Prompt,[switch]$AsSecureString)
        if ($AsSecureString) { throw 'Must not ask for a token before validating ClientID' }
        $script:AskedClientId = $Prompt -match 'ClientID'
        return 'invalid-client-id'
    }
    function script:Initialize-YdbWindowsState { throw 'Must not initialize state before validating ClientID' }
    $message = ''
    try { Connect-YdbAccount | Out-Null } catch { $message = $_.Exception.Message }
    if (-not $script:AskedClientId) { throw 'ASSERTION FAILED: no bundled OAuth application; prompt for user ClientID first' }
    if ($message -notmatch 'ClientID') { throw 'ASSERTION FAILED: invalid ClientID must fail before state or token access' }
}
$launcher = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../package/Start-Backup.ps1'))
Assert-True ($launcher.Contains("'YandexDiskBackup-Public'")) 'Public settings must not reuse the original project namespace'
Assert-True (-not $launcher.Contains("'YandexDiskBackup'")) 'Original settings namespace must not be used'
Write-Host 'PASS: user-supplied OAuth ClientID; no original settings/token namespace reuse'
