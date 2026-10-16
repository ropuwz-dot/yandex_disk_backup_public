$ErrorActionPreference = 'Stop'
function Assert-True($c, [string]$m) { if (-not $c) { throw "ASSERTION FAILED: $m" } }
foreach ($scenario in @('gone','wrong-login','wrong-account','cancel')) {
    Import-Module (Join-Path $PSScriptRoot '../package/Backup.Windows.psm1') -Force -DisableNameChecking
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ydb-failure-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        $old = @{ Version=1; Profile='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; UserId='12345'; Login='test-user'; Source='ydisk:Фото'; Destination=(Join-Path $root 'backup') }
        $before = $old | ConvertTo-Json
        [IO.File]::WriteAllText((Join-Path $root 'settings.json'), $before)
        $module = Get-Module Backup.Windows
        & $module { param($scenario)
            $script:scenario = $scenario
            $script:values = New-Object 'Collections.Generic.Queue[object]'
            if ($scenario -eq 'cancel') { $script:values.Enqueue('НЕТ') }
            else {
                $script:values.Enqueue('ДА')
                $script:values.Enqueue((ConvertTo-SecureString 'y0_SYNTHETIC_LOCAL_TEST_ONLY' -AsPlainText -Force))
                if ($scenario -eq 'wrong-login') { $script:values.Enqueue('incorrect') }
                elseif ($scenario -eq 'wrong-account') { $script:values.Enqueue('other') }
                else { $script:values.Enqueue('test-user') }
            }
            function script:Read-Host { param($Prompt,[switch]$AsSecureString) $script:values.Dequeue() }
            function script:Start-Process { param($FilePath) }
            function script:Protect-YdbPrivateDirectory { param($Path) [IO.Directory]::CreateDirectory($Path) | Out-Null }
            function script:Get-YdbAccount {
                if ($script:scenario -eq 'wrong-account') { [pscustomobject]@{ UserId='67890'; Login='other' } }
                else { [pscustomobject]@{ UserId='12345'; Login='test-user' } }
            }
            function script:Invoke-YdbCapture {
                if ($script:scenario -eq 'gone') { [pscustomobject]@{ ExitCode=1; Output=''; ErrorText='[410 - GoneError] Gone' } }
                else { [pscustomobject]@{ ExitCode=0; Output='[]'; ErrorText='' } }
            }
        } $scenario
        $failed = $false
        $result = $null
        try { $result = Connect-YdbAccount -ClientId '0123456789abcdef0123456789abcdef' -Executable 'fixture' -StateRoot $root } catch { $failed = $true }
        if ($scenario -in @('gone','wrong-login')) {
            Assert-True $failed ('Must reject ' + $scenario)
            Assert-True ([IO.File]::ReadAllText((Join-Path $root 'settings.json')) -ceq $before) 'Failed connection preserves exact old settings bytes'
            Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $root 'profiles') -Force).Count -eq 0) 'Failed temporary token profile is removed'
        } elseif ($scenario -eq 'wrong-account') {
            Assert-True (-not $failed -and $result.UserId -eq '67890') 'Explicitly confirmed new account connects'
            Assert-True ($result.Source -eq 'ydisk:' -and $result.Destination -eq '') 'Different account cannot inherit previous backup destination'
        } else {
            Assert-True ($null -eq $result -and -not $failed) 'Cancel creates no connection'
            Assert-True ([IO.File]::ReadAllText((Join-Path $root 'settings.json')) -ceq $before) 'Cancel preserves old settings'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'profiles'))) 'Cancel creates no token directory'
        }
        Write-Host ('PASS: custom connection scenario ' + $scenario)
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}
