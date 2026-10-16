Set-StrictMode -Version 2.0

function Get-YdbNetworkArguments {
    param([switch]$ForCopy)
    if ($ForCopy) {
        # Yandex Open and the outer copy loop both apply low-level retries.
        # Do not multiply minute-long header waits before the next file gets its turn.
        return @('--tpslimit','2','--tpslimit-burst','1','--checkers','1',
          '--retries','1','--retries-sleep','0s','--low-level-retries','1',
          '--contimeout','15s','--timeout','15s')
    }
    @('--tpslimit','2','--tpslimit-burst','1','--checkers','1',
      '--retries','3','--retries-sleep','30s','--low-level-retries','3',
      '--contimeout','30s','--timeout','5m')
}

function Get-YdbCopyArguments {
    param([string]$Source, [string]$Destination, [string]$Config, [string]$Log)
    @('copy',$Source,$Destination,'--config',$Config,
      '--transfers','1','--multi-thread-streams','0','--checksum','--immutable',
      '--create-empty-src-dirs','--stats','1s',
      '--log-file',$Log,'--log-level','INFO') + @(Get-YdbNetworkArguments -ForCopy)
}

function ConvertTo-YdbSource {
    param([string]$Path)
    $relative = $Path.Trim().Replace('\','/')
    if ($relative.StartsWith('disk:/')) { $relative = $relative.Substring(6) }
    $relative = $relative.Trim('/')
    if ($relative -match '[:\x00-\x1f]' -or $relative.Split('/') -contains '..' -or $relative.Split('/') -contains '.') {
        throw 'Недопустимый путь на Диске. Укажите / или путь папки без .. и без ссылки.'
    }
    'ydisk:' + $relative
}

function New-YdbBinding {
    param([string]$UserId, [string]$Login, [string]$Source)
    if ($UserId -notmatch '^\d+$' -or -not $Source.StartsWith('ydisk:')) { throw 'Invalid account or source binding' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($UserId + "`n" + $Source))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    [pscustomobject]@{ Version = 1; UserId = $UserId; Login = $Login; Source = $Source; Key = $hash.Substring(0,16) }
}

function Assert-YdbBinding {
    param($Expected, $Actual)
    if ($Expected.Version -ne 1 -or $Actual.Version -ne 1 -or
        $Expected.UserId -cne $Actual.UserId -or $Expected.Source -cne $Actual.Source -or $Expected.Key -cne $Actual.Key) {
        throw 'Аккаунт или исходная папка отличаются от привязки этой копии. Выберите отдельную папку назначения.'
    }
}

function Write-YdbJson {
    param([string]$Path, $Value)
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 16), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Assert-YdbNoReparsePoint {
    param([string]$Path, [switch]$Recursive)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Ссылка/junction недопустима в назначении: $current" }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
    if ($Recursive -and (Test-Path -LiteralPath $Path)) {
        $queue = New-Object 'Collections.Generic.Stack[string]'
        $queue.Push([IO.Path]::GetFullPath($Path))
        while ($queue.Count -gt 0) {
            foreach ($item in Get-ChildItem -LiteralPath $queue.Pop() -Force -ErrorAction Stop) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Ссылка/junction недопустима: $($item.FullName)" }
                if ($item.PSIsContainer) { $queue.Push($item.FullName) }
            }
        }
    }
}

function Initialize-YdbDestination {
    param([string]$Destination, $Binding)
    if (-not [IO.Path]::IsPathRooted($Destination)) { throw 'Папка назначения должна быть абсолютным локальным путём.' }
    Assert-YdbNoReparsePoint -Path $Destination -Recursive
    $bindingFile = Join-Path $Destination '.ydb-binding.json'
    if (Test-Path -LiteralPath $bindingFile) {
        Assert-YdbBinding -Expected $Binding -Actual ([IO.File]::ReadAllText($bindingFile) | ConvertFrom-Json)
    } else {
        if ((Test-Path -LiteralPath $Destination) -and @(Get-ChildItem -LiteralPath $Destination -Force).Count -gt 0) {
            throw 'Папка уже содержит посторонние файлы. Выберите отдельную пустую папку.'
        }
        [IO.Directory]::CreateDirectory($Destination) | Out-Null
        Write-YdbJson -Path $bindingFile -Value $Binding
    }
    foreach ($name in @('Files','Reports')) { [IO.Directory]::CreateDirectory((Join-Path $Destination $name)) | Out-Null }
}

function ConvertTo-YdbNativeArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    '"' + $escaped + '"'
}

function Invoke-YdbCapture {
    param([string]$Executable, [string[]]$Arguments,
          [string]$Activity = 'Ожидание ответа rclone', [string]$ProgressLog = '')
    $ProgressPreference = 'Continue'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-YdbNativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $started = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $tick = 0
    [long]$logStart = 0
    if ($ProgressLog -and (Test-Path -LiteralPath $ProgressLog)) { $logStart = (Get-Item -LiteralPath $ProgressLog).Length }
    $lastSignature = ''
    $lastChange = 0.0
    try {
        if (-not $process.Start()) { throw 'Не удалось запустить rclone.' }
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        do {
            $percent = -1
            $details = 'Ожидаем ответ / список файлов; процент пока неизвестен.'
            $tail = ''
            if ($ProgressLog -and (Test-Path -LiteralPath $ProgressLog)) {
                $stream = $null
                try {
                    $stream = [IO.File]::Open($ProgressLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                    # Ignore previous passes; bound memory and work even for very large logs.
                    if ($stream.Length -lt $logStart) { $logStart = 0 }
                    $offset = [Math]::Max($logStart, $stream.Length - 32768)
                    [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
                    $buffer = New-Object byte[] ([int]($stream.Length - $offset))
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    $tail = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                } catch [IO.IOException] {
                    # A temporarily unavailable display log must not abort the transfer.
                } finally { if ($stream) { $stream.Dispose() } }
            }
            $byteRows = [regex]::Matches($tail, '(?m)^Transferred:[ \t]*([^\x0D\x0A]*\b(?:Bytes|[KMGTPE]?i?B)[ \t]*/[^\x0D\x0A]*)')
            if ($byteRows.Count -gt 0) { $tail = $tail.Substring($byteRows[$byteRows.Count - 1].Index) }
            $fileRows = [regex]::Matches($tail, '(?m)^Transferred:[ \t]*(\d+[ \t]*/[ \t]*\d+[^\x0D\x0A]*)')
            $checkRows = [regex]::Matches($tail, '(?m)^Checks:[ \t]*(\d+[ \t]*/[ \t]*\d+[^\x0D\x0A]*)')
            $activeRows = [regex]::Matches($tail, '(?m)^ \*[ \t]+([^\x0D\x0A]+)')
            $signature = ''
            if ($byteRows.Count -gt 0) {
                $value = $byteRows[$byteRows.Count - 1].Groups[1].Value.Trim()
                $details = 'Передано: ' + ($value -replace '\s+', ' ')
                if ($value -match ',\s*(\d+)%') { $percent = [Math]::Min(100, [int]$Matches[1]) }
                $signature += ($value -split ',')[0]
            }
            if ($fileRows.Count -gt 0) {
                $value = $fileRows[$fileRows.Count - 1].Groups[1].Value.Trim()
                $details += '; Файлы: ' + ($value -replace '\s+', ' ')
                $signature += '|' + ($value -split ',')[0]
            }
            if ($checkRows.Count -gt 0) {
                $value = $checkRows[$checkRows.Count - 1].Groups[1].Value.Trim()
                $details += '; Проверено: ' + ($value -replace '\s+', ' ')
                $signature += '|' + ($value -split ',')[0]
                if ($Arguments[0] -eq 'check' -and $value -match ',\s*(\d+)%') { $percent = [Math]::Min(100, [int]$Matches[1]) }
            }
            if ($activeRows.Count -gt 0) {
                $value = $activeRows[$activeRows.Count - 1].Groups[1].Value.Trim()
                $details += '; Текущий файл: ' + $value
                $signature += '|' + ($value -split ':\s*\d+%')[0]
            }
            $errorRows = [regex]::Matches($tail, '(?m)^Errors:[ \t]*(\d+)')
            if ($errorRows.Count -gt 0) {
                $value = $errorRows[$errorRows.Count - 1].Groups[1].Value
                $details += '; Ошибок: ' + $value
                $signature += '|errors:' + $value
            }
            if ($signature -ne $lastSignature) { $lastSignature = $signature; $lastChange = $clock.Elapsed.TotalSeconds }
            $status = ('{0} Прошло {1:hh\:mm\:ss}; без нового прогресса {2:N0} с.' -f @('|','/','-','\')[$tick % 4], $clock.Elapsed, ($clock.Elapsed.TotalSeconds - $lastChange))
            Write-Progress -Id 71 -Activity $Activity -Status $status -CurrentOperation $details -PercentComplete $percent
            # Never echo raw stderr or error log lines: they can contain signed URLs.
            if ([Console]::IsOutputRedirected) { Write-Host ($Activity + ': ' + $status + ' ' + $details) }
            $tick++
        } while (-not $process.WaitForExit(1000))
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result; ErrorText = $stderr.Result }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        Write-Progress -Id 71 -Activity $Activity -Completed
        $process.Dispose()
        $clock.Stop()
    }
}

function Invoke-YdbLive {
    param([string]$Executable, [string[]]$Arguments)
    $activity = 'Скачивание — текущий проход (не итог проверки)'
    if ($Arguments[0] -eq 'check') { $activity = 'Проверка размеров и контрольных сумм' }
    $log = ''
    $index = [Array]::IndexOf($Arguments, '--log-file')
    if ($index -ge 0 -and $index + 1 -lt $Arguments.Count) { $log = $Arguments[$index + 1] }
    $result = Invoke-YdbCapture -Executable $Executable -Arguments $Arguments -Activity $activity -ProgressLog $log
    Write-Host ('{0}: этап завершён, код {1}. Полноту копии определяет итоговая проверка.' -f $activity, $result.ExitCode)
    return [int]$result.ExitCode
}

function Get-YdbInventory {
    param([string]$Executable, [string]$Config, [string]$Source, [string]$ReportDirectory)
    $arguments = @('lsjson',$Source,'--recursive','--hash-type','MD5','--no-mimetype','--config',$Config) + @(Get-YdbNetworkArguments)
    $result = Invoke-YdbCapture -Executable $Executable -Arguments $arguments
    [IO.File]::WriteAllText((Join-Path $ReportDirectory 'inventory-errors.log'), $result.ErrorText, (New-Object Text.UTF8Encoding($false)))
    if ($result.ExitCode -ne 0) { throw 'Не удалось получить полный список файлов. Скачивание не начато; см. inventory-errors.log.' }
    # Pre-7 ConvertFrom-Json emits a JSON array as ONE pipeline object.
    # Capture first, then enumerate the assigned value explicitly on every supported version.
    $parsed = ConvertFrom-Json -InputObject $result.Output -ErrorAction Stop
    $items = @()
    if ($null -ne $parsed) { $items = @($parsed) }
    $files = @($items | Where-Object { -not $_.IsDir })
    [long]$bytes = 0
    foreach ($file in $files) {
        if ($file.Size -lt 0) { throw 'В списке есть файл неизвестного размера; проверьте список.' }
        $bytes += [long]$file.Size
    }
    [IO.File]::WriteAllText((Join-Path $ReportDirectory 'inventory.json'), $result.Output, (New-Object Text.UTF8Encoding($false)))
    [pscustomobject]@{ FileCount = $files.Count; Bytes = $bytes; DirectoryCount = @($items | Where-Object { $_.IsDir }).Count }
}

function Get-YdbCheckArguments {
    param([string]$Source, [string]$Destination, [string]$Config, [string]$ReportDirectory)
    @('check',$Source,$Destination,'--config',$Config,'--one-way',
      '--combined',(Join-Path $ReportDirectory 'check-combined.txt'),
      '--match',(Join-Path $ReportDirectory 'check-matched.txt'),
      '--differ',(Join-Path $ReportDirectory 'check-different.txt'),
      '--missing-on-dst',(Join-Path $ReportDirectory 'check-missing.txt'),
      '--error',(Join-Path $ReportDirectory 'check-errors.txt'),
      '--log-file',(Join-Path $ReportDirectory 'check.log'),'--log-level','INFO',
      '--stats','1s') + @(Get-YdbNetworkArguments)
}

function Invoke-YdbBackup {
    param([string]$Executable, [string]$Config, $Binding, [string]$Destination)
    Initialize-YdbDestination -Destination $Destination -Binding $Binding
    $reports = Join-Path (Join-Path $Destination 'Reports') ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
    [IO.Directory]::CreateDirectory($reports) | Out-Null
    $journal = [ordered]@{ Status = 'inventory'; Verified = $false; StartedUtc = [DateTime]::UtcNow.ToString('o'); Binding = $Binding; Reports = $reports; InventoryFiles = 0; MatchedFiles = 0; CopyExitCode = $null; CheckExitCode = $null }
    $journalPath = Join-Path $reports 'result.json'
    Write-YdbJson -Path $journalPath -Value $journal
    Write-Host 'Получение полного списка файлов (скачивание ещё не началось)...'
    try {
        $inventory = Get-YdbInventory -Executable $Executable -Config $Config -Source $Binding.Source -ReportDirectory $reports
        $journal.InventoryFiles = $inventory.FileCount
        $journal['InventoryBytes'] = $inventory.Bytes
        if ($inventory.FileCount -eq 0) {
            throw 'Источник вернул 0 файлов. Полная копия НЕ подтверждена; копирование не начато. Проверьте путь папки НА ЯНДЕКС ДИСКЕ и её доступность. Список источника сохранён в inventory.json текущего отчёта.'
        }
        $journal.Status = 'copying'
        Write-YdbJson -Path $journalPath -Value $journal
        Write-Host ("Найдено файлов: {0}; объём: {1:N2} ГиБ. Скачивание строго по одному." -f $inventory.FileCount, ($inventory.Bytes / 1GB))
        $data = Join-Path $Destination 'Files'
        $parsedInventory = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $reports 'inventory.json')))
        $sourceFiles = @($parsedInventory | Where-Object { -not $_.IsDir })
        $journal['Passes'] = @()
        $journal['RetryCount'] = 0
        $retryList = $null
        do {
            $pass = $journal.RetryCount + 1
            $journal.Status = 'copying'
            Write-YdbJson -Path $journalPath -Value $journal
            Write-Host ("Проход {0}: ожидание ответа/простоя 15 секунд; автоматических повторов нет." -f $pass)
            $copyArguments = @(Get-YdbCopyArguments -Source $Binding.Source -Destination $data -Config $Config -Log (Join-Path $reports 'copy.log'))
            if ($retryList) { $copyArguments += @('--files-from-raw', $retryList) }
            $journal.CopyExitCode = Invoke-YdbLive -Executable $Executable -Arguments $copyArguments
            if ($journal.CopyExitCode -eq 130) { throw 'Скачивание остановлено. Следующий запуск пропустит проверенные готовые файлы.' }
            $journal.Status = 'checking'
            Write-YdbJson -Path $journalPath -Value $journal
            Write-Host 'Проверка размеров и контрольных сумм. Затем будет предложен повтор недоступных файлов.'
            # Never reuse stale matches from an earlier pass after an unsuccessful check.
            foreach ($name in @('check-matched.txt','check-missing.txt','check-different.txt','check-errors.txt','check-combined.txt')) {
                $path = Join-Path $reports $name
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            }
            $checkArguments = @(Get-YdbCheckArguments -Source $Binding.Source -Destination $data -Config $Config -ReportDirectory $reports)
            $journal.CheckExitCode = Invoke-YdbLive -Executable $Executable -Arguments $checkArguments
            if ($journal.CheckExitCode -eq 130) { throw 'Проверка остановлена. Полная копия не подтверждена.' }
            $matched = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            $matchFile = Join-Path $reports 'check-matched.txt'
            if (Test-Path -LiteralPath $matchFile) {
                foreach ($path in [IO.File]::ReadAllLines($matchFile)) { [void]$matched.Add($path) }
            }
            $journal.MatchedFiles = $matched.Count
            $journal['FailedFiles'] = @($sourceFiles | Where-Object { -not $matched.Contains([string]$_.Path) } | ForEach-Object { [string]$_.Path })
            $journal.Verified = ($journal.CopyExitCode -eq 0 -and $journal.CheckExitCode -eq 0 -and $journal.MatchedFiles -eq $journal.InventoryFiles -and $journal.FailedFiles.Count -eq 0)
            $journal.Passes += @([pscustomobject]@{ Pass = $pass; CopyExitCode = $journal.CopyExitCode; CheckExitCode = $journal.CheckExitCode; MatchedFiles = $journal.MatchedFiles; FailedFiles = @($journal.FailedFiles) })
            if ($journal.Verified) { $journal.Status = 'verified' } else { $journal.Status = 'incomplete' }
            Write-YdbJson -Path $journalPath -Value $journal
            if ($journal.Verified -or $journal.FailedFiles.Count -eq 0) { break }
            Write-Host ("Не удалось скачать/подтвердить файлов: {0}. Остальные файлы уже обработаны. Конфликтующие локальные файлы не перезаписываются." -f $journal.FailedFiles.Count) -ForegroundColor Yellow
            $journal.Status = 'awaiting-retry'
            Write-YdbJson -Path $journalPath -Value $journal
            do {
                $answer = ([string](Read-Host 'Повторить скачивание недоступных файлов? ДА/НЕТ')).Trim().ToUpperInvariant()
                if ($answer -notin @('ДА','НЕТ')) { Write-Host 'Введите ДА или НЕТ.' }
            } while ($answer -notin @('ДА','НЕТ'))
            if ($answer -eq 'НЕТ') { $journal.Status = 'incomplete'; break }
            # Raw file list preserves spaces, Unicode and filter metacharacters literally.
            # Reject unrepresentable records rather than silently retrying a different path.
            foreach ($path in $journal.FailedFiles) {
                if ($path.IndexOf([char]13) -ge 0 -or $path.IndexOf([char]10) -ge 0) { throw 'Имя файла содержит перевод строки: безопасный повтор по списку невозможен.' }
            }
            $journal.RetryCount++
            $retryList = Join-Path $reports ("retry-{0}-files.txt" -f $journal.RetryCount)
            [IO.File]::WriteAllLines($retryList, [string[]]$journal.FailedFiles, (New-Object Text.UTF8Encoding($false)))
        } while ($true)
    } catch {
        $journal.Status = 'incomplete'
        $journal['Failure'] = $_.Exception.Message
        Write-YdbJson -Path $journalPath -Value $journal
        throw
    } finally {
        $journal['FinishedUtc'] = [DateTime]::UtcNow.ToString('o')
        Write-YdbJson -Path $journalPath -Value $journal
    }
    [pscustomobject]$journal
}

Export-ModuleMember -Function Get-YdbCopyArguments, ConvertTo-YdbSource, New-YdbBinding, Assert-YdbBinding, Write-YdbJson, Assert-YdbNoReparsePoint, Invoke-YdbCapture, Invoke-YdbLive, Get-YdbCheckArguments, Invoke-YdbBackup
