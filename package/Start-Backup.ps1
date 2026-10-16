#requires -Version 5.1
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem) {
    Write-Host 'Этот запускатель предназначен для 64-битной Windows 10/11.'
    exit 1
}
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# Changes only the environment of this dedicated PowerShell process, not Windows settings.
foreach ($variable in @(Get-ChildItem Env:RCLONE_*)) { Remove-Item -LiteralPath ('Env:' + $variable.Name) }
Import-Module (Join-Path $PSScriptRoot 'Backup.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Backup.Windows.psm1') -Force -DisableNameChecking
$lock = $null
try {
    $stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'YandexDiskBackup-Public'
    Protect-YdbPrivateDirectory -Path $stateRoot
    try { $lock = [IO.File]::Open((Join-Path $stateRoot 'app.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Уже запущена другая копия программы для этого пользователя. Закройте её перед новым запуском.' }
    $executable = Initialize-YdbRclone -PackageDirectory $PSScriptRoot -PrivateDirectory $stateRoot
    if ($SelfTest) {
        $version = Invoke-YdbCapture -Executable $executable -Arguments @('version')
        if ($version.ExitCode -ne 0) { throw 'rclone не запустился.' }
        Write-Host $version.Output
        Write-Host 'Проверка архива, rclone.exe, закрытой папки и запуска завершена. Диск не подключался, файлы не скачивались.' -ForegroundColor Green
        exit 0
    }
    $settings = $null
    $settingsPath = Join-Path $stateRoot 'settings.json'
    if (Test-Path -LiteralPath $settingsPath) {
        try { $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json }
        catch { Write-Host 'Сохранённые настройки не читаются. Подключите аккаунт заново через пункт 1.' -ForegroundColor Yellow }
    }
    while ($true) {
        Write-Host "`n=== ЯНДЕКС ДИСК: РЕЗЕРВНАЯ КОПИЯ PUBLIC 1.1.7 (индикатор прогресса; тайм-аут 15 секунд) ===" -ForegroundColor Cyan
        if ($settings) {
            Write-Host ("Аккаунт: {0}; источник: {1}" -f $settings.Login, $settings.Source)
            if ($settings.Destination) { Write-Host ('Назначение: ' + $settings.Destination + '\Files') }
        } else { Write-Host 'Аккаунт ещё не подключён.' }
        Write-Host '1 — Подключить аккаунт через своё приложение (токен вводится скрыто здесь)'
        Write-Host '2 — Выбрать исходную папку и место сохранения'
        Write-Host '3 — Начать / продолжить скачивание по одному файлу'
        Write-Host '4 — Открыть папку отчётов'
        Write-Host '5 — Забыть текущее локальное подключение'
        Write-Host '0 — Выход'
        try {
            switch (Read-Host 'Введите номер') {
                '1' {
                    $connected = Connect-YdbAccount -Executable $executable -StateRoot $stateRoot
                    if ($connected) { $settings = $connected }
                }
                '2' {
                    if (-not $settings) { throw 'Сначала подключите аккаунт через пункт 1.' }
                    $settings = Set-YdbSelection -Settings $settings -StateRoot $stateRoot
                }
                '3' {
                    if (-not $settings) { throw 'Сначала подключите аккаунт через пункт 1.' }
                    Start-YdbSelectedBackup -Executable $executable -StateRoot $stateRoot -Settings $settings
                }
                '4' {
                    if (-not $settings -or -not $settings.Destination) { throw 'Папка назначения ещё не выбрана.' }
                    $reports = Join-Path $settings.Destination 'Reports'
                    if (-not (Test-Path -LiteralPath $reports)) { throw 'Отчётов пока нет: скачивание ещё не запускалось.' }
                    Invoke-Item -LiteralPath $reports
                }
                '5' {
                    if (-not $settings) { throw 'Нет активного подключения.' }
                    if ((Read-Host 'Удалить только локальный токен и настройки? Копии файлов останутся. Введите ДА') -match '^(ДА|YES|Y)$') {
                        $config = Get-YdbProfileConfig -StateRoot $stateRoot -Settings $settings
                        if (Test-Path -LiteralPath $config) { Remove-Item -LiteralPath $config -Force }
                        Remove-Item -LiteralPath $settingsPath -Force
                        $settings = $null
                        Write-Host 'Локальное подключение забыто. Для отзыва доступа rclone используйте настройки Яндекс ID.'
                    }
                }
                '0' { return }
                default { Write-Host 'Выберите пункт 0–5.' }
            }
        } catch { Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red; Write-Host 'Успешная полная копия не подтверждена. Оригиналы на Диске не изменялись.' }
    }
} catch { Write-Host ('ОШИБКА ЗАПУСКА: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($lock) { $lock.Dispose() } }
