$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '../package/Backup.Windows.psm1'
if (Test-Path $module) { Import-Module $module -Force -DisableNameChecking }
function Assert-True($condition, [string]$message) { if (-not $condition) { throw "ASSERTION FAILED: $message" } }
Assert-True ([bool](Get-Command ConvertFrom-YdbDiskIdentity -ErrorAction SilentlyContinue)) 'Missing verified account identity parser'
$good = ConvertFrom-YdbDiskIdentity ([pscustomobject]@{ user = [pscustomobject]@{ uid = '12345'; login = 'test-user'; display_name = 'Тестовый пользователь' } })
Assert-True ($good.UserId -eq '12345' -and $good.Login -eq 'test-user') 'Use explicit Yandex account ID and login'
foreach ($bad in @([pscustomobject]@{}, [pscustomobject]@{user=@{uid='';login='test-user'}}, [pscustomobject]@{user=@{uid='123';login=''}})) {
    $rejected = $false
    try { ConvertFrom-YdbDiskIdentity $bad | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Unknown account must fail closed'
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('ydb-auth-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $config = Join-Path $root 'private.conf'
    [IO.File]::WriteAllText($config, '[ydisk]' + "`ntype = yandex`ntoken = {" + '"access_token":"SYNTHETIC_TEST_ONLY"}' + "`n")
    Assert-True ((Read-YdbToken $config) -eq 'SYNTHETIC_TEST_ONLY') 'Read exact own remote token without logging it'
    [IO.File]::WriteAllText($config, '[other]' + "`ntype = yandex`ntoken = {" + '"access_token":"SYNTHETIC_TEST_ONLY"}' + "`n")
    $rejected = $false
    try { Read-YdbToken $config | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Never take a token from another remote'
    Write-Host 'PASS: account identity and isolated token parsing (synthetic fixtures, no login)'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
