$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '../package/Backup.Core.psm1'
if (Test-Path $module) { Import-Module $module -Force -DisableNameChecking }
function Assert-True($condition, [string]$message) { if (-not $condition) { throw "ASSERTION FAILED: $message" } }
Assert-True ([bool](Get-Command Get-YdbCopyArguments -ErrorAction SilentlyContinue)) 'Missing sequential copy argument builder'
$args = @(Get-YdbCopyArguments -Source 'ydisk:Фото' -Destination '/tmp/data' -Config '/tmp/private.conf' -Log '/tmp/log.json')
Assert-True ($args[0] -eq 'copy') 'Only copy, never sync or move'
foreach ($pair in @(@('--transfers','1'), @('--checkers','1'), @('--multi-thread-streams','0'), @('--tpslimit','2'), @('--low-level-retries','1'), @('--retries','1'), @('--timeout','15s'), @('--contimeout','15s'), @('--retries-sleep','0s'))) {
    $index = [Array]::IndexOf($args, $pair[0])
    Assert-True ($index -ge 0 -and $args[$index + 1] -eq $pair[1]) "Safety option $($pair[0])"
}
Assert-True ($args -contains '--checksum') 'Use checksum for resume'
Assert-True ($args -contains '--immutable') 'Never overwrite conflicting existing files'
Assert-True ($args -notcontains '--ignore-existing') 'Existing corrupt files must not be silently accepted'
Assert-True ($args -notcontains '--inplace') 'Incomplete files are not final files'
Write-Host 'PASS: sequential copy safety'
Assert-True ([bool](Get-Command ConvertTo-YdbSource -ErrorAction SilentlyContinue)) 'Missing source path validation'
Assert-True ((ConvertTo-YdbSource 'disk:/Фото/Семья/') -eq 'ydisk:Фото/Семья') 'Normalize source'
Assert-True ((ConvertTo-YdbSource '/') -eq 'ydisk:') 'Root source'
foreach ($bad in @('../escape','Folder/../escape','https://example.org','trash:/','Folder/./x')) {
    $rejected = $false
    try { ConvertTo-YdbSource $bad | Out-Null } catch { $rejected = $true }
    Assert-True $rejected "Reject unsafe source: $bad"
}
$a = New-YdbBinding -UserId '123' -Login 'test-user' -Source 'ydisk:Фото'
$b = New-YdbBinding -UserId '456' -Login 'test-user' -Source 'ydisk:Фото'
Assert-True ($a.Key -ne $b.Key) 'Same login on different account must have isolated backup'
Assert-True ((New-YdbBinding -UserId '123' -Login 'renamed' -Source 'ydisk:Фото').Key -eq $a.Key) 'Bind to stable ID, not login'
$rejected = $false
try { Assert-YdbBinding -Expected $a -Actual $b } catch { $rejected = $true }
Assert-True $rejected 'Reject account switch'
Write-Host 'PASS: source validation and account binding'
$jsonPath = Join-Path ([IO.Path]::GetTempPath()) ('ydb-json-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    Write-YdbJson -Path $jsonPath -Value @{ status = 'pending' }
    Write-YdbJson -Path $jsonPath -Value @{ status = 'verified' }
    Assert-True (([IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json).status -eq 'verified') 'Atomic journal updates replace existing file'
} finally { if (Test-Path $jsonPath) { Remove-Item $jsonPath -Force } }
Write-Host 'PASS: atomic journal update'
$guardRoot = Join-Path ([IO.Path]::GetTempPath()) ('ydb-guard-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $guardRoot | Out-Null
    $real = Join-Path $guardRoot 'real'
    New-Item -ItemType Directory -Path $real | Out-Null
    $link = Join-Path $guardRoot 'linked'
    New-Item -ItemType SymbolicLink -Path $link -Target $real | Out-Null
    $rejected = $false
    try { Assert-YdbNoReparsePoint -Path (Join-Path $link 'nested') } catch { $rejected = $true }
    Assert-True $rejected 'Reject symlink ancestor'
    $rejected = $false
    try { Assert-YdbNoReparsePoint -Path $guardRoot -Recursive } catch { $rejected = $true }
    Assert-True $rejected 'Reject nested symlink'
    $check = @(Get-YdbCheckArguments -Source 'ydisk:' -Destination $real -Config 'private.conf' -ReportDirectory $guardRoot)
    Assert-True ($check[0] -eq 'check' -and $check -contains '--one-way') 'Verification never deletes destination extras'
    foreach ($flag in @('--match','--differ','--missing-on-dst','--error','--combined')) { Assert-True ($check -contains $flag) 'Full check reports' }
    Write-Host 'PASS: destination symlink protection and check report contract'
} finally { if (Test-Path $guardRoot) { Remove-Item -LiteralPath $guardRoot -Recurse -Force } }
