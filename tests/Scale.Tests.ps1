param([int]$FileCount = 40000, [string]$Rclone = $(if ($env:YDB_RCLONE) { $env:YDB_RCLONE } else { 'rclone' }))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../package/Backup.Core.psm1') -Force -DisableNameChecking
$root = Join-Path ([IO.Path]::GetTempPath()) ('ydb-scale-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    $source = Join-Path $root 'source'
    [IO.Directory]::CreateDirectory($source) | Out-Null
    for ($index = 0; $index -lt $FileCount; $index++) {
        $directory = Join-Path $source ('Группа ' + [int][Math]::Floor($index / 1000))
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $directory ($index.ToString('D6') + '.txt')), 'fixture ' + $index)
    }
    $config = Join-Path $root 'local-test.conf'
    [IO.File]::WriteAllText($config, "[ydisk]`ntype = alias`nremote = $source`n")
    $binding = New-YdbBinding -UserId '999' -Login 'LOCAL_SCALE_FIXTURE_ONLY' -Source 'ydisk:'
    $result = Invoke-YdbBackup -Executable $Rclone -Config $config -Binding $binding -Destination (Join-Path $root 'destination')
    if (-not $result.Verified -or $result.MatchedFiles -ne $FileCount -or $result.InventoryFiles -ne $FileCount) { throw 'Scale coverage mismatch' }
    $watch.Stop()
    $receipt = @{ source = 'synthetic local fixture; not Yandex'; verifiedFiles = $result.MatchedFiles; inventoryFiles = $result.InventoryFiles; seconds = $watch.Elapsed.TotalSeconds; copyExitCode = $result.CopyExitCode; checkExitCode = $result.CheckExitCode; windowsRuntime = 'not exercised' }
    Write-Host ('SCALE_PASS ' + ($receipt | ConvertTo-Json -Compress))
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
