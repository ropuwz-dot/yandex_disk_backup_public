$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../package/Backup.Windows.psm1') -Force -DisableNameChecking
function Assert-True($condition, [string]$message) { if (-not $condition) { throw "ASSERTION FAILED: $message" } }
Assert-True ([bool](Get-Command Write-YdbCustomOAuthConfig -ErrorAction SilentlyContinue)) 'Missing custom OAuth configuration writer'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ydb-custom-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    $config = Join-Path $root 'private.conf'
    $clientId = '0123456789abcdef0123456789abcdef'
    $secret = ConvertTo-SecureString 'y0_SYNTHETIC_LOCAL_TEST_ONLY' -AsPlainText -Force
    $output = @(Write-YdbCustomOAuthConfig -Path $config -ClientId $clientId -Token $secret)
    Assert-True ($output.Count -eq 0) 'Writer must not emit token or config'
    Assert-True ((Read-YdbToken -Config $config) -ceq 'y0_SYNTHETIC_LOCAL_TEST_ONLY') 'Use exact locally entered token'
    $text = [IO.File]::ReadAllText($config)
    Assert-True ($text.Contains('client_id = ' + $clientId)) 'Bind config to exact public ClientID'
    Assert-True (-not $text.Contains('client_secret')) 'No client secret required'
    Assert-True (-not $text.Contains('expiry')) 'Never invent token expiry'
    $failed = $false
    try { Write-YdbCustomOAuthConfig -Path $config -ClientId $clientId -Token $secret } catch { $failed = $true }
    Assert-True $failed 'Refuse overwrite of an existing profile'
    foreach ($bad in @('https://example.org', "y0_token`n[type]", '')) {
        $candidate = Join-Path $root ([Guid]::NewGuid().ToString('N') + '.conf')
        $failed = $false
        try {
            $badSecret = ConvertTo-SecureString $bad -AsPlainText -Force
            Write-YdbCustomOAuthConfig -Path $candidate -ClientId $clientId -Token $badSecret
        } catch { $failed = $true }
        Assert-True $failed 'Reject URL, multiline or empty token'
        Assert-True (-not (Test-Path -LiteralPath $candidate)) 'Invalid token must not create config'
    }
    $failed = $false
    try { Write-YdbCustomOAuthConfig -Path (Join-Path $root 'invalid.conf') -ClientId 'bad-client' -Token $secret } catch { $failed = $true }
    Assert-True $failed 'Reject malformed ClientID without normalization'
    Write-Host 'PASS: custom OAuth local secret storage, exact ClientID, no output, no overwrite, invalid input rejection'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
