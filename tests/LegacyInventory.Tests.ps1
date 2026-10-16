param([string]$Rclone = $(if ($env:YDB_RCLONE) { $env:YDB_RCLONE } else { 'rclone' }))
$ErrorActionPreference = 'Stop'
function Assert-True($c,[string]$m) { if (-not $c) { throw "ASSERTION FAILED: $m" } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('ydb-legacy-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    $source = Join-Path $root 'source'
    [IO.Directory]::CreateDirectory((Join-Path $source 'nested/empty')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'one.txt'),'abc')
    [IO.File]::WriteAllText((Join-Path $source 'nested/two.txt'),'defgh')
    [IO.File]::WriteAllBytes((Join-Path $source 'zero.bin'),[byte[]]@())
    $config = Join-Path $root 'fixture.conf'
    [IO.File]::WriteAllText($config,"[ydisk]`ntype = alias`nremote = $source`n")
    foreach ($mode in @('legacy','modern')) {
        Import-Module (Join-Path $PSScriptRoot '../package/Backup.Core.psm1') -Force -DisableNameChecking
        if ($mode -eq 'legacy') {
            $module = Get-Module Backup.Core
            & $module {
                # Reproduce pre-7 ConvertFrom-Json array-as-one-output behavior, NOT a native Windows run.
                function script:ConvertFrom-Json {
                    [CmdletBinding()]
                    param([Parameter(ValueFromPipeline=$true)][string]$InputObject)
                    process {
                        $parsed = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject -NoEnumerate
                        Write-Output -NoEnumerate $parsed
                    }
                }
            }
        }
        $binding = New-YdbBinding -UserId '12345' -Login 'local-fixture' -Source 'ydisk:'
        $result = Invoke-YdbBackup -Executable $Rclone -Config $config -Binding $binding -Destination (Join-Path $root ('backup-' + $mode))
        Assert-True ($result.InventoryFiles -eq 3) ($mode + ' must enumerate actual three files, not array-as-one')
        Assert-True ($result.InventoryBytes -eq 8) ($mode + ' exact source byte count')
        Assert-True ($result.MatchedFiles -eq 3 -and $result.Verified) ($mode + ' actual copy/check agrees with inventory')
        Write-Host ('PASS: actual rclone copy/check with ' + $mode + ' JSON enumeration; 3 files,8 bytes')
        $emptyBinding = New-YdbBinding -UserId '12345' -Login 'local-fixture' -Source 'ydisk:nested/empty'
        $emptyDestination = Join-Path $root ('empty-' + $mode)
        $blocked = $false
        try { Invoke-YdbBackup -Executable $Rclone -Config $config -Binding $emptyBinding -Destination $emptyDestination | Out-Null } catch { $blocked = $true }
        Assert-True $blocked ($mode + ' zero-file source must not become a verified full copy')
        $run = @(Get-ChildItem -LiteralPath (Join-Path $emptyDestination 'Reports') -Directory)[0]
        $journal = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $run.FullName 'result.json')))
        Assert-True (-not $journal.Verified -and $journal.InventoryFiles -eq 0 -and $null -eq $journal.CopyExitCode -and $null -eq $journal.CheckExitCode) 'Zero-file source is stopped before copy/check and journal never claims success'
        Write-Host ('PASS: zero-file guard with ' + $mode + ' JSON enumeration')
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
