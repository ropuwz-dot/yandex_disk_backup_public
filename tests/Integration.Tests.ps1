param([string]$Rclone = $(if ($env:YDB_RCLONE) { $env:YDB_RCLONE } else { 'rclone' }))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../package/Backup.Core.psm1') -Force -DisableNameChecking
function Assert-True($condition, [string]$message) { if (-not $condition) { throw "ASSERTION FAILED: $message" } }
Assert-True ([bool](Get-Command Invoke-YdbBackup -ErrorAction SilentlyContinue)) 'Missing end-to-end backup operation'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ydb-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $source = Join-Path $root 'источник с пробелами'
    New-Item -ItemType Directory -Path (Join-Path $source 'Фото семьи/Пустая папка') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'Фото семьи/файл [1] & %.txt'), 'Здравствуйте!')
    [IO.File]::WriteAllBytes((Join-Path $source 'пустой.bin'), [byte[]]@())
    [IO.File]::WriteAllBytes((Join-Path $source 'data.bin'), [byte[]](0..255))
    $config = Join-Path $root 'private.conf'
    [IO.File]::WriteAllText($config, "[ydisk]`ntype = alias`nremote = $source`n")
    $binding = New-YdbBinding -UserId '123' -Login 'test-local-fixture' -Source 'ydisk:'
    $destination = Join-Path $root 'копия'
    $first = Invoke-YdbBackup -Executable $Rclone -Config $config -Binding $binding -Destination $destination
    Assert-True $first.Verified 'Fresh backup must verify'
    Assert-True ($first.InventoryFiles -eq 3 -and $first.MatchedFiles -eq 3) 'Inventory and checksum match count'
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'Files/Фото семьи/Пустая папка')) 'Preserve empty directories'
    $file = Join-Path $destination 'Files/Фото семьи/файл [1] & %.txt'
    $before = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    $timeBefore = (Get-Item -LiteralPath $file).LastWriteTimeUtc
    $second = Invoke-YdbBackup -Executable $Rclone -Config $config -Binding $binding -Destination $destination
    Assert-True $second.Verified 'Repeated run verifies without re-download'
    Assert-True ((Get-Item -LiteralPath $file).LastWriteTimeUtc -eq $timeBefore) 'Resume does not rewrite verified bytes'
    Assert-True ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $before) 'Preserve content'
    [IO.File]::WriteAllText($file, 'CHANGED LOCALLY')
    & (Get-Module Backup.Core) { function script:Read-Host { param($Prompt) 'НЕТ' } }
    $third = Invoke-YdbBackup -Executable $Rclone -Config $config -Binding $binding -Destination $destination
    Assert-True (-not $third.Verified -and $third.CopyExitCode -ne 0) 'Conflicting destination fails, not success'
    Assert-True ([IO.File]::ReadAllText($file) -eq 'CHANGED LOCALLY') 'Never overwrite local conflict'
    Assert-True (Test-Path -LiteralPath (Join-Path $source 'data.bin')) 'Source never deleted'
    $other = New-YdbBinding -UserId '456' -Login 'other' -Source 'ydisk:'
    $rejected = $false
    try { Invoke-YdbBackup -Executable $Rclone -Config $config -Binding $other -Destination $destination | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Reject a different account at same destination'
    Write-Host 'PASS: real rclone local fixture, Unicode, empty files/folders, resume, conflicts, account isolation'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
