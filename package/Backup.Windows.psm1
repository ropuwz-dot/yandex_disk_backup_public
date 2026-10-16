Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Backup.Core.psm1') -DisableNameChecking

function ConvertFrom-YdbDiskIdentity {
    param($Response)
    $uid = [string]$Response.user.uid
    $login = [string]$Response.user.login
    if ($uid -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace($login)) { throw 'Яндекс не вернул однозначный ID и логин аккаунта. Продолжать небезопасно.' }
    [pscustomobject]@{ UserId = $uid; Login = $login }
}

function Read-YdbToken {
    param([string]$Config)
    $inside = $false
    $tokenText = $null
    $type = $null
    foreach ($line in [IO.File]::ReadAllLines($Config)) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $inside = ($Matches[1] -ceq 'ydisk'); continue }
        if (-not $inside) { continue }
        if ($line -match '^\s*type\s*=\s*(.+?)\s*$') { $type = $Matches[1] }
        if ($line -match '^\s*token\s*=\s*(\{.+\})\s*$') { $tokenText = $Matches[1] }
    }
    if ($type -ne 'yandex' -or -not $tokenText) { throw 'В отдельном профиле нет подключения ydisk типа yandex.' }
    try { $token = $tokenText | ConvertFrom-Json } catch { throw 'Локальный файл авторизации повреждён. Подключите аккаунт заново.' }
    if ([string]::IsNullOrWhiteSpace($token.access_token)) { throw 'В подключении отсутствует токен.' }
    [string]$token.access_token
}

function Format-YdbSafeFailure {
    param([ValidateSet('rclone-about','account-api','root-listing')][string]$Stage, [int]$ExitCode = 0, [string]$ErrorText = '', [int]$HttpStatus = 0)
    $status = 'unknown'
    $category = 'unknown'
    if ($HttpStatus -ge 400 -and $HttpStatus -le 599) { $status = [string]$HttpStatus }
    elseif ($ErrorText -match '\[([45][0-9]{2})\s*-') { $status = $Matches[1] }
    elseif ($ErrorText -match '(?i)HTTP(?:/[0-9.]+)?\s*(?:error|status(?: code)?)?\s*[:=]?\s+([45][0-9]{2})\b') { $status = $Matches[1] }
    switch ($status) {
        '401' { $category = 'unauthorized' }
        '403' { $category = 'forbidden-check-permissions' }
        '404' { $category = 'not-found' }
        '410' { $category = 'gone' }
        '429' { $category = 'rate-limit' }
        default { if ($status -match '^5') { $category = 'provider-server-error' } }
    }
    if ($status -eq 'unknown') {
        if ($ErrorText -match 'unable to get RefreshToken') { $category = 'local-config-missing-refresh-token' }
        elseif ($ErrorText -match '(?i)timed? out|timeout|deadline exceeded') { $category = 'timeout' }
        elseif ($ErrorText -match '(?i)invalid_client|invalid_grant|invalid_token|oauth2:') { $category = 'oauth-error' }
        elseif ($ErrorText -match '(?i)x509|certificate|TLS handshake') { $category = 'tls-error' }
        elseif ($ErrorText -match '(?i)no such host|name resolution|DNS') { $category = 'dns-error' }
        elseif ($ErrorText -match '(?i)connection refused|connectex|network is unreachable') { $category = 'network-error' }
    }
    # Construct from fixed labels/numbers only. Never return raw stderr, response body, token, URL or local path.
    'stage=' + $Stage + '; exit=' + $ExitCode + '; HTTP=' + $status + '; type=' + $category
}

function Get-YdbAccount {
    param([string]$Executable, [string]$Config)
    $result = Invoke-YdbCapture -Executable $Executable -Arguments @('about','ydisk:','--json','--config',$Config,'--retries','2','--low-level-retries','2','--contimeout','30s','--timeout','60s')
    if ($result.ExitCode -ne 0) {
        $safe = Format-YdbSafeFailure -Stage 'rclone-about' -ExitCode $result.ExitCode -ErrorText $result.ErrorText
        throw ('Проверка доступа не пройдена. Диагностика: ' + $safe + '. Скачивание не начато. Передайте эту строку без токена.')
    }
    $token = Read-YdbToken -Config $Config
    try {
        $response = Invoke-RestMethod -Uri 'https://cloud-api.yandex.net/v1/disk?fields=user' -Method Get -Headers @{ Authorization = ('OAuth ' + $token) } -TimeoutSec 60 -MaximumRedirection 0 -ErrorAction Stop
    } catch {
        $httpStatus = 0
        $exception = $_.Exception
        if ($exception.PSObject.Properties['Response'] -and $null -ne $exception.Response -and $exception.Response.PSObject.Properties['StatusCode']) {
            $httpStatus = [int]$exception.Response.StatusCode
        }
        $safe = Format-YdbSafeFailure -Stage 'account-api' -HttpStatus $httpStatus -ErrorText $exception.Message
        throw ('Не удалось подтвердить аккаунт. Диагностика: ' + $safe + '. Скачивание не начато. Передайте эту строку без токена.')
    }
    finally { $token = $null }
    ConvertFrom-YdbDiskIdentity -Response $response
}

function Protect-YdbPrivateDirectory {
    param([string]$Path)
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    Assert-YdbNoReparsePoint -Path $Path
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $acl = New-Object Security.AccessControl.DirectorySecurity
    # Mark only the DACL as changed. Do not rewrite Owner, Group or Audit/SACL:
    # those sections can require privileges unavailable to a normal user.
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in @($identity.User, (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    # Set-Acl first copies ALL descriptor sections (including SACL), and its
    # privilege-recovery heuristic can request SeSecurityPrivilege again for an
    # already protected directory. Native .NET persists only modified sections.
    $directory = New-Object IO.DirectoryInfo($Path)
    if ($directory.PSObject.Methods['SetAccessControl']) {
        $directory.SetAccessControl($acl) # Windows PowerShell 5.1 / .NET Framework
    } else {
        [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl) # PowerShell 7 on Windows
    }
}

function Initialize-YdbRclone {
    param([string]$PackageDirectory, [string]$PrivateDirectory)
    $zip = Join-Path $PackageDirectory 'vendor/rclone-v1.75.2-windows-amd64.zip'
    $zipHash = '8a9db2bad1dc79a65b3348fd857069598e2aab7cf4d118b77b1df23055aff818'
    $exeHash = '41eab3e118d264920b62c3327966c5ece0dc4dd715ee617d9e30450d8ead95a4'
    if (-not (Test-Path -LiteralPath $zip) -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $zipHash) { throw 'Архив rclone отсутствует или повреждён. Не запускаю непроверенный файл.' }
    $tools = Join-Path $PrivateDirectory 'tools'
    Assert-YdbNoReparsePoint -Path $tools -Recursive
    $exe = Join-Path $tools 'rclone-v1.75.2-windows-amd64/rclone.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Host 'Распаковка проверенного rclone (только при первом запуске)...'
        Expand-Archive -LiteralPath $zip -DestinationPath $tools -Force
    }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $exeHash) { throw 'rclone.exe не прошёл проверку целостности. Скачивание не запускается.' }
    $exe
}

function Get-YdbProfileConfig {
    param([string]$StateRoot, $Settings)
    if ($Settings.Profile -notmatch '^[a-f0-9]{32}$') { throw 'Повреждён ID локального профиля.' }
    Join-Path (Join-Path (Join-Path $StateRoot 'profiles') $Settings.Profile) 'rclone.conf'
}

function Connect-YdbAccount {
    param([string]$Executable, [string]$StateRoot, [string]$ClientId = '')
    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        $ClientId = Read-Host 'Введите ClientID вашего OAuth-приложения Яндекса (32 hex)'
    }
    if ($ClientId -cnotmatch '^[a-f0-9]{32}$') { throw 'Некорректный ClientID приложения.' }
    $authorizeUrl = 'https://oauth.yandex.ru/authorize?response_type=token&client_id=' + $ClientId
    Write-Host 'Подключение через ваше OAuth-приложение Яндекса, не стандартное приложение rclone.'
    Write-Host 'В браузере войдите именно в нужный аккаунт. Нужны только чтение Диска и информация о Диске.'
    Write-Host 'Яндекс покажет токен. Скопируйте только токен и вставьте в скрытое поле ЭТОГО окна.'
    Write-Host 'Токен нельзя отправлять в чат, скриншоты или переписку. ClientSecret не требуется.'
    if ((Read-Host 'Открыть авторизацию? Введите ДА') -notmatch '^(ДА|YES|Y)$') { return $null }
    $profileDirectoryId = [Guid]::NewGuid().ToString('N')
    $profileDirectory = Join-Path (Join-Path $StateRoot 'profiles') $profileDirectoryId
    Protect-YdbPrivateDirectory -Path $profileDirectory
    $config = Join-Path $profileDirectory 'rclone.conf'
    $committed = $false
    $secret = $null
    try {
        Write-Host ('Адрес авторизации: ' + $authorizeUrl)
        try { Start-Process -FilePath $authorizeUrl | Out-Null }
        catch { Write-Host 'Браузер не открылся. Откройте указанный выше адрес вручную.' }
        $secret = Read-Host 'ВСТАВЬТЕ ТОКЕН СЮДА и нажмите Enter (ввод скрыт; пустой ввод = отмена)' -AsSecureString
        Write-YdbCustomOAuthConfig -Path $config -ClientId $ClientId -Token $secret
        $secret.Dispose(); $secret = $null
        Write-Host 'Проверка аккаунта и доступа к списку файлов...'
        $account = Get-YdbAccount -Executable $Executable -Config $config
        $probe = Invoke-YdbCapture -Executable $Executable -Arguments @('lsjson','ydisk:','--max-depth','1','--no-mimetype','--config',$config,'--retries','1','--low-level-retries','1','--contimeout','20s','--timeout','60s','--tpslimit','2','--checkers','1')
        if ($probe.ExitCode -ne 0) {
            $safe = Format-YdbSafeFailure -Stage 'root-listing' -ExitCode $probe.ExitCode -ErrorText $probe.ErrorText
            throw ('Список файлов недоступен. Диагностика: ' + $safe + '. Старое подключение сохранено; скачивание не начато.')
        }
        try { $null = $probe.Output | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'Яндекс не вернул корректный список файлов. Новое подключение не сохранено.' }
        Write-Host ("Подключён Диск: {0}; ID: {1}" -f $account.Login, $account.UserId) -ForegroundColor Cyan
        if ((Read-Host ("В ЭТОМ ОКНЕ введите логин {0} и нажмите Enter для подтверждения аккаунта" -f $account.Login)) -cne $account.Login) {
            throw 'Логин не подтверждён. Новое подключение не сохранено; старый выбор оставлен без изменений.'
        }
        $settings = [pscustomobject]@{ Version = 1; Profile = $profileDirectoryId; UserId = $account.UserId; Login = $account.Login; Source = 'ydisk:'; Destination = '' }
        $settingsPath = Join-Path $StateRoot 'settings.json'
        if (Test-Path -LiteralPath $settingsPath) {
            $previous = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
            if ($previous.UserId -ceq $account.UserId) {
                $settings.Source = $previous.Source
                $settings.Destination = $previous.Destination
            }
        }
        Write-YdbJson -Path $settingsPath -Value $settings
        $committed = $true
        Write-Host 'Аккаунт и чтение списка проверены. Файлы ещё не скачивались. Удалите токен из буфера обмена и закройте страницу с ним.' -ForegroundColor Green
        $settings
    } finally {
        if ($secret) { $secret.Dispose() }
        if (-not $committed -and (Test-Path -LiteralPath $profileDirectory)) { Remove-Item -LiteralPath $profileDirectory -Recurse -Force }
    }
}

function Set-YdbSelection {
    param($Settings, [string]$StateRoot)
    $relative = Read-Host 'Что скачать? / = весь Диск, либо путь папки (например Фото/2025). Enter = весь Диск'
    $source = ConvertTo-YdbSource -Path $relative
    $base = (Read-Host 'Куда сохранить? Укажите локальную папку, например D:\YandexDiskCopies').Trim().Trim('"')
    if ($base -notmatch '^[A-Za-z]:[\\/]' -or $base.Substring(2).Contains(':')) { throw 'Укажите локальный абсолютный путь с буквой диска, не ссылку и не сетевой адрес.' }
    $base = [IO.Path]::GetFullPath($base)
    $binding = New-YdbBinding -UserId $Settings.UserId -Login $Settings.Login -Source $source
    $destination = Join-Path $base ('YandexDisk-' + $Settings.UserId + '-' + $binding.Key)
    Assert-YdbNoReparsePoint -Path $destination -Recursive
    $Settings.Source = $source
    $Settings.Destination = $destination
    Write-YdbJson -Path (Join-Path $StateRoot 'settings.json') -Value $Settings
    Write-Host ("Файлы будут здесь: {0}\Files" -f $destination)
    $Settings
}

function Start-YdbSelectedBackup {
    param([string]$Executable, [string]$StateRoot, $Settings)
    if ([string]::IsNullOrWhiteSpace($Settings.Destination)) { throw 'Сначала выберите источник и папку назначения (пункт 2).' }
    $config = Get-YdbProfileConfig -StateRoot $StateRoot -Settings $Settings
    $account = Get-YdbAccount -Executable $Executable -Config $config
    if ($account.UserId -cne $Settings.UserId) { throw 'Текущий аккаунт отличается от сохранённого. Загрузка заблокирована, чтобы не смешать Диски.' }
    Write-Host ("Аккаунт: {0}; ID {1}`nИсточник: {2}`nНазначение: {3}\Files" -f $account.Login, $account.UserId, $Settings.Source, $Settings.Destination) -ForegroundColor Cyan
    Write-Host 'Оригиналы не меняются. Существующие отличающиеся локальные файлы не перезаписываются.'
    if ((Read-Host 'Начать/продолжить? Введите ДА') -notmatch '^(ДА|YES|Y)$') { return }
    if (-not ('YdbPowerState' -as [type])) {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class YdbPowerState { [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags); }'
    }
    [YdbPowerState]::SetThreadExecutionState([uint32]2147483649) | Out-Null
    try {
        $binding = New-YdbBinding -UserId $account.UserId -Login $account.Login -Source $Settings.Source
        $result = Invoke-YdbBackup -Executable $Executable -Config $config -Binding $binding -Destination $Settings.Destination
        if ($result.Verified) { Write-Host ("ГОТОВО: проверено файлов {0}." -f $result.MatchedFiles) -ForegroundColor Green }
        else { Write-Host 'КОПИЯ НЕПОЛНАЯ: есть ошибки или изменения исходного списка. Смотрите отчёты и повторите запуск позже.' -ForegroundColor Yellow }
        Write-Host ('Отчёты: ' + $result.Reports)
    } finally { [YdbPowerState]::SetThreadExecutionState([uint32]2147483648) | Out-Null }
}

function Write-YdbCustomOAuthConfig {
    param([string]$Path, [string]$ClientId, [Security.SecureString]$Token)
    if ($ClientId -cnotmatch '^[a-f0-9]{32}$') { throw 'Некорректный ClientID приложения.' }
    if ($null -eq $Token -or $Token.Length -eq 0) { throw 'Токен не введён.' }
    $pointer = [IntPtr]::Zero
    $plain = $null
    $json = $null
    $content = $null
    $stream = $null
    $writer = $null
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ($plain -cnotmatch '^[A-Za-z0-9_-]{20,4096}$') { throw 'Нужен только токен со страницы Яндекса, без URL, пробелов и переносов строк.' }
        Assert-YdbNoReparsePoint -Path $Path
        # Yandex backend refuses an empty RefreshToken even for a valid non-expiring access token.
        # 'none' is an explicit compatibility marker, NOT a refresh credential. No expiry is invented.
        # With zero/omitted expiry oauth2 uses the access token directly; renewal remains manual.
        $json = @{ access_token = $plain; token_type = 'OAuth'; refresh_token = 'none' } | ConvertTo-Json -Compress
        $content = "[ydisk]`n" + "type = yandex`nclient_id = $ClientId`ntoken = $json`n"
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false)))
        $writer.Write($content)
        $writer.Flush()
    } finally {
        if ($writer) { $writer.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        $plain = $null; $json = $null; $content = $null
    }
}

Export-ModuleMember -Function Format-YdbSafeFailure, Write-YdbCustomOAuthConfig, ConvertFrom-YdbDiskIdentity, Read-YdbToken, Get-YdbAccount, Protect-YdbPrivateDirectory, Initialize-YdbRclone, Get-YdbProfileConfig, Connect-YdbAccount, Set-YdbSelection, Start-YdbSelectedBackup
