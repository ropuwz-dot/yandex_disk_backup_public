$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../package/Backup.Windows.psm1') -Force -DisableNameChecking
function Assert-True($c, [string]$m) { if (-not $c) { throw "ASSERTION FAILED: $m" } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('ydb-connect-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    $old = @{ Version = 1; Profile = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; UserId = '12345'; Login = 'test-user'; Source = 'ydisk:Фото'; Destination = (Join-Path $root 'backup') }
    [IO.File]::WriteAllText((Join-Path $root 'settings.json'), ($old | ConvertTo-Json))
    $module = Get-Module Backup.Windows
    & $module {
        $script:testPrompts = New-Object 'Collections.Generic.List[string]'
        $script:testValues = New-Object 'Collections.Generic.Queue[object]'
        $script:testValues.Enqueue('ДА')
        $script:testValues.Enqueue((ConvertTo-SecureString 'y0_SYNTHETIC_LOCAL_TEST_ONLY' -AsPlainText -Force))
        $script:testValues.Enqueue('test-user')
        $script:testBrowser = ''
        $script:testListingCalls = 0
        function script:Read-Host { param([string]$Prompt, [switch]$AsSecureString)
            $script:testPrompts.Add($Prompt)
            $v = $script:testValues.Dequeue()
            if ($v -is [Security.SecureString] -and -not $AsSecureString) { throw 'Token input not masked' }
            $v
        }
        function script:Start-Process { param([string]$FilePath) $script:testBrowser = $FilePath }
        function script:Protect-YdbPrivateDirectory { param([string]$Path) [IO.Directory]::CreateDirectory($Path) | Out-Null }
        function script:Get-YdbAccount { param($Executable,$Config)
            if ((Read-YdbToken $Config) -cne 'y0_SYNTHETIC_LOCAL_TEST_ONLY') { throw 'Wrong token in identity preflight' }
            [pscustomobject]@{ UserId = '12345'; Login = 'test-user' }
        }
        function script:Invoke-YdbCapture { param($Executable,[string[]]$Arguments)
            if ($Arguments[0] -ne 'lsjson' -or $Arguments[1] -ne 'ydisk:' -or $Arguments -notcontains '--max-depth') { throw 'Missing bounded real file-listing probe' }
            $script:testListingCalls++
            [pscustomobject]@{ ExitCode = 0; Output = '[]'; ErrorText = '' }
        }
        function script:Invoke-YdbLive { throw 'Default rclone OAuth must not be used' }
    }
    $settings = Connect-YdbAccount -ClientId '0123456789abcdef0123456789abcdef' -Executable 'unused-fixture' -StateRoot $root
    Assert-True ($settings.UserId -eq '12345') 'Connected exact account'
    Assert-True ($settings.Profile -ne $old.Profile) 'Isolate new credentials'
    Assert-True ($settings.Source -eq $old.Source -and $settings.Destination -eq $old.Destination) 'Preserve copy selection for same account'
    $state = & $module { @{ browser = $script:testBrowser; prompts = @($script:testPrompts); listingCalls = $script:testListingCalls } }
    Assert-True ($state.browser -ceq 'https://oauth.yandex.ru/authorize?response_type=token&client_id=0123456789abcdef0123456789abcdef') 'Official custom-app implicit flow only'
    Assert-True ($state.listingCalls -eq 1) 'Check file listing, not just identity'
    Assert-True ([bool]($state.prompts | Where-Object { $_ -match 'test-user' })) 'Show expected login inside terminal prompt'
    Assert-True (([IO.File]::ReadAllText((Join-Path $root 'settings.json')) | ConvertFrom-Json).Profile -eq $settings.Profile) 'Commit only verified new profile'
    Write-Host 'PASS: complete custom OAuth connection flow with simulated UI/network, masked local input and preserved same-account selection'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
