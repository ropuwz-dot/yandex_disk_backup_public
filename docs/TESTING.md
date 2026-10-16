# Фактические проверки Public 1.1.7

Проверено 16 октября 2026 года. Среда: Linux x64, PowerShell 7.6.7, rclone 1.75.2, PSScriptAnalyzer 1.25.0. Это не нативный прогон Windows 10/11.

## Регрессия

Команда: `python tests/run.py` с инструментами через `YDB_PWSH` / `YDB_RCLONE`.

Результат: **15/15 тестовых скриптов, ошибок 0**. Это число скриптов, а не число отдельных assertions.

- `Core.Tests.ps1` — exit 0.
- `CustomConnection.Tests.ps1` — exit 0.
- `CustomConnectionFailures.Tests.ps1` — exit 0.
- `CustomOAuth.Tests.ps1` — exit 0.
- `Integration.Tests.ps1` — exit 0.
- `LegacyInventory.Tests.ps1` — exit 0.
- `PrivateDirectoryAcl.Tests.ps1` — exit 0.
- `Progress.Tests.py` — exit 0.
- `ProgressSyntax.Tests.ps1` — exit 0.
- `PublicIsolation.Tests.ps1` — exit 0.
- `RetryPrompt.Tests.py` — exit 0.
- `SafeDiagnostics.Tests.ps1` — exit 0.
- `Scale.Tests.ps1` — exit 0.
- `StalledDownload.Tests.py` — exit 0.
- `Windows.Tests.ps1` — exit 0.

Проверены настоящий локальный rclone copy/check/resume и конфликт, 40 000 синтетических файлов, отсутствие ложного успеха на пустом источнике, account/source binding, старый JSON-enumeration, HTTP timeout, повторы ДА/НЕТ и живой индикатор. Изменения public OAuth ClientID prompt прошли RED → GREEN; отдельный тест проверяет, что launcher не использует прежний каталог настроек. Windows ACL и OAuth/UI в этих сценариях симулированы. Parser и PSUseCompatibleSyntax target 5.1 прошли, но это не выполнение на PowerShell 5.1.

## Секреты и состав

- Собственные файлы проекта: Gitleaks 8.30.1, `gitleaks dir . --redact=100` — 0 находок.
- Выполнена дополнительная локальная проверка известных личных идентификаторов и абсолютных служебных путей — совпадений нет. Список частных значений не публикуется.
- Старая Git-история, runtime-конфиги, настройки, приватные инструкции, логи, receipts и пользовательские данные не включены.
- Публичные тестовые значения намеренно синтетические и не дают доступа к аккаунтам. Бинарники приложения не модифицировались для маскировки результатов сканера.

## Зависимость rclone

Архив `package/vendor/rclone-v1.75.2-windows-amd64.zip` сверён с официальным `https://downloads.rclone.org/v1.75.2/SHA256SUMS`:

- ZIP SHA-256: `8a9db2bad1dc79a65b3348fd857069598e2aab7cf4d118b77b1df23055aff818`.
- Встроенный `rclone.exe` SHA-256: `41eab3e118d264920b62c3327966c5ece0dc4dd715ee617d9e30450d8ead95a4`.
- ZIP CRC — без ошибок.

При `gitleaks dir . --max-archive-depth 2 --redact=100` получено **20 срабатываний внутри документации неизменённого официального архива** (`rclone.1`, `README.html`, `README.txt`: примеры API-ключей/приватных ключей). Это upstream-содержимое, а не внесённые проектом пользовательские credentials; совпадение официального архива подтверждено SHA-256. Поэтому глубокое сканирование не объявляется «0 находок», исключения на весь vendor-каталог не добавлялись. При повторной проверке сканер может снова показать эти примеры.

## Не выполнялось

- Настоящая новая OAuth-авторизация или чтение пользовательского Яндекс Диска.
- Нативный запуск PUBLIC-редакции на Windows, проверка настоящего DACL или Windows UI.
- Необязательный внешний отрицательный тест `RealYandexBackend.Tests.ps1`.
- Push, изменение удалённого репозитория, тег или GitHub Release.

Прогон тестов не доказывает полноту чьей-либо облачной копии. Публичная подготовка не меняет и не останавливает отдельно запущенную рабочую программу.
