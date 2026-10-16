param([string]$Rclone = $(if ($env:YDB_RCLONE) { $env:YDB_RCLONE } else { 'rclone' }))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../package/Backup.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../package/Backup.Windows.psm1') -Force -DisableNameChecking
function Assert-True($c,[string]$m) { if (-not $c) { throw "ASSERTION FAILED: $m" } }
$path = Join-Path ([IO.Path]::GetTempPath()) ('ydb-real-yandex-' + [Guid]::NewGuid().ToString('N') + '.conf')
try {
    # Deliberately invalid synthetic credential. This test has NO access to user files.
    $secret = ConvertTo-SecureString 'y0_SYNTHETIC_INVALID_NO_USER_ACCESS' -AsPlainText -Force
    Write-YdbCustomOAuthConfig -Path $path -ClientId '0123456789abcdef0123456789abcdef' -Token $secret
    $result = Invoke-YdbCapture -Executable $Rclone -Arguments @('about','ydisk:','--json','--config',$path,'--retries','1','--low-level-retries','1','--contimeout','10s','--timeout','15s')
    Assert-True (-not $result.ErrorText.Contains('unable to get RefreshToken')) 'Generated config must initialize real Yandex backend without local RefreshToken failure'
    Assert-True ($result.ExitCode -ne 0 -and $result.ErrorText.Contains('[401 - UnauthorizedError]')) 'Fake credential must reach official API and be rejected with real HTTP401, not local setup failure'
    $text = [IO.File]::ReadAllText($path)
    Assert-True (-not $text.Contains('expiry')) 'Do not invent an expiry to fix compatibility'
    Assert-True (-not $text.Contains('client_secret')) 'No client secret added'
    Write-Host 'PASS: generated config initializes actual rclone Yandex backend; deliberate invalid test token reaches API and receives401; NOT a user-account success test'
} finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
