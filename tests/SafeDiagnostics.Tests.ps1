$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../package/Backup.Windows.psm1') -Force -DisableNameChecking
function Assert-True($c,[string]$m) { if (-not $c) { throw "ASSERTION FAILED: $m" } }
Assert-True ([bool](Get-Command Format-YdbSafeFailure -ErrorAction SilentlyContinue)) 'Missing safe error diagnostics'
$raw = '[403 - ForbiddenError] Forbidden; Authorization OAuth y0_SYNTHETIC_SECRET_NOT_FOR_OUTPUT; private path C:\Users\Private\rclone.conf'
$summary = Format-YdbSafeFailure -Stage 'rclone-about' -ExitCode 1 -ErrorText $raw
Assert-True ($summary.Contains('HTTP=403') -and $summary.Contains('rclone-about')) 'Identify stage and provider status'
Assert-True (-not $summary.Contains('y0_') -and -not $summary.Contains('Private') -and -not $summary.Contains('Authorization')) 'Never echo raw stderr or private context'
foreach ($code in @(401,404,410,429,500,502,503,504)) {
    $s = Format-YdbSafeFailure -Stage 'rclone-about' -ExitCode 1 -ErrorText ("[$code - TestError] y0_SYNTHETIC_SECRET_NOT_FOR_OUTPUT")
    Assert-True ($s.Contains("HTTP=$code") -and -not $s.Contains('y0_')) 'Status without secrets'
}
$timeout = Format-YdbSafeFailure -Stage 'rclone-about' -ExitCode 1 -ErrorText 'context deadline exceeded; y0_SYNTHETIC_SECRET_NOT_FOR_OUTPUT'
Assert-True ($timeout.Contains('timeout') -and $timeout.Contains('HTTP=unknown')) 'Do not invent HTTP status for network failure'
$opaque = Format-YdbSafeFailure -Stage 'rclone-about' -ExitCode 1 -ErrorText 'unknown crash y0_SYNTHETIC_SECRET_NOT_FOR_OUTPUT'
Assert-True ($opaque.Contains('unknown') -and -not $opaque.Contains('y0_')) 'Opaque failure stays opaque'
$module = Get-Module Backup.Windows
& $module {
    function script:Invoke-YdbCapture { [pscustomobject]@{ ExitCode=1; Output=''; ErrorText='[401 - UnauthorizedError] y0_SYNTHETIC_SECRET_NOT_FOR_OUTPUT' } }
}
$failure = ''
try { Get-YdbAccount -Executable 'fixture' -Config 'unused' | Out-Null } catch { $failure = $_.Exception.Message }
Assert-True ($failure.Contains('rclone-about') -and $failure.Contains('HTTP=401')) 'Actual failing account path retains useful status'
Assert-True (-not $failure.Contains('y0_')) 'Actual failing path does not leak token'
& $module {
    function script:Invoke-YdbCapture { [pscustomobject]@{ ExitCode=0; Output='{}'; ErrorText='' } }
    function script:Read-YdbToken { 'y0_SYNTHETIC_SECRET_NOT_FOR_OUTPUT' }
    function script:Invoke-RestMethod {
        $ex = New-Object Exception('private y0_SYNTHETIC_SECRET_NOT_FOR_OUTPUT')
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode=403 })
        throw $ex
    }
}
$failure = ''
try { Get-YdbAccount -Executable 'fixture' -Config 'unused' | Out-Null } catch { $failure = $_.Exception.Message }
Assert-True ($failure.Contains('account-api') -and $failure.Contains('HTTP=403')) 'Independent account API failure retains HTTP status'
Assert-True (-not $failure.Contains('y0_')) 'Account HTTP exception body is not echoed'
$compatFailure = Format-YdbSafeFailure -Stage 'rclone-about' -ExitCode 1 -ErrorText 'unable to get RefreshToken. y0_SYNTHETIC_SECRET_NOT_FOR_OUTPUT'
Assert-True ($compatFailure.Contains('type=local-config-missing-refresh-token') -and $compatFailure.Contains('HTTP=unknown')) 'Identify local Yandex backend RefreshToken guard without inventing HTTP'
Assert-True (-not $compatFailure.Contains('y0_')) 'RefreshToken diagnostics never echo secrets'
Write-Host 'PASS: safe diagnostics preserve stage/status, reject secret echo, distinguish timeout and exercise actual account failure'
