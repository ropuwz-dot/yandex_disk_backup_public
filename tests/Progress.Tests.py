"""Exercise the real PowerShell process runner; never use cloud credentials."""
from pathlib import Path
import subprocess, tempfile, time

ROOT = Path(__file__).resolve().parents[1]
from tool_paths import PWSH, RCLONE


def heartbeat():
    with tempfile.TemporaryDirectory(prefix='ydb-progress-') as tmp:
        tmp = Path(tmp)
        child = tmp / 'child с пробелом.ps1'
        child.write_text("Start-Sleep -Seconds 4; [Console]::Out.Write('payload'); [Console]::Error.Write('private signed URL'); exit 7", encoding='utf-8-sig')
        runner = tmp / 'runner.ps1'
        runner.write_text('''param($Module,$Pwsh,$Child)
$ErrorActionPreference='Stop'
Import-Module $Module -Force -DisableNameChecking
$r=Invoke-YdbCapture -Executable $Pwsh -Arguments @('-NoProfile','-File',$Child)
if ($r.ExitCode -ne 7 -or $r.Output -ne 'payload' -or $r.ErrorText -ne 'private signed URL') {throw 'Capture contract changed'}
Write-Host 'CAPTURE-PASS'
''', encoding='utf-8-sig')
        start = time.monotonic()
        proc = subprocess.Popen([str(PWSH), '-NoProfile', '-File', str(runner), '-Module', str(ROOT/'package/Backup.Core.psm1'), '-Pwsh', str(PWSH), '-Child', str(child)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='strict')
        lines = [(time.monotonic()-start, line) for line in proc.stdout]
        rc = proc.wait(timeout=15)
        text = ''.join(line for _, line in lines)
        assert rc == 0, text
        updates = [(t, s) for t, s in lines if 'Прошло' in s]
        assert len(updates) >= 3, ('No periodic console heartbeat during silent process', lines)
        assert updates[0][0] < 2 and updates[-1][0] >= 3, lines
        assert 'private signed URL' not in text, 'Raw child stderr leaked to console'
        assert 'CAPTURE-PASS' in text
        print('PASS: live heartbeat before silent child exit, Unicode arguments, output/exit contract, no secret echo')


def transfer_progress():
    with tempfile.TemporaryDirectory(prefix='ydb-transfer-progress-') as tmp:
        tmp = Path(tmp)
        (tmp/'source').mkdir()
        payload = b'progress fixture\n' * 327680
        (tmp/'source'/'файл [1].bin').write_bytes(payload)
        runner = tmp/'copy.ps1'
        runner.write_text('''param($Module,$Rclone,$Source,$Destination,$Log)
$ErrorActionPreference='Stop'
Import-Module $Module -Force -DisableNameChecking
$a=@(Get-YdbCopyArguments -Source $Source -Destination $Destination -Config '/dev/null' -Log $Log)
$i=[Array]::IndexOf($a,'--tpslimit');$a[$i+1]='0'
$a+=@('--bwlimit','1M')
$code=Invoke-YdbLive -Executable $Rclone -Arguments $a
if ($code -ne 0) {throw "Copy failed: $code"}
Write-Host 'COPY-PASS'
''', encoding='utf-8-sig')
        r = subprocess.run([str(PWSH), '-NoProfile', '-File', str(runner), '-Module', str(ROOT/'package/Backup.Core.psm1'), '-Rclone', str(RCLONE), '-Source', str(tmp/'source'), '-Destination', str(tmp/'destination'), '-Log', str(tmp/'copy.log')], capture_output=True, text=True, encoding='utf-8', errors='strict', timeout=25)
        assert r.returncode == 0, r.stdout+r.stderr
        assert (tmp/'destination'/'файл [1].bin').read_bytes() == payload
        import re
        assert re.search(r'Передано: .*\b[1-9][0-9]?%', r.stdout), ('No determinate byte progress', r.stdout)
        assert 'файл [1].bin' in r.stdout, ('No active filename', r.stdout)
        assert 'Файлы:' in r.stdout and 'ETA' in r.stdout, r.stdout
        check_runner = tmp/'check.ps1'
        check_runner.write_text('''param($Module,$Rclone,$Source,$Destination,$Reports)
$ErrorActionPreference='Stop'
Import-Module $Module -Force -DisableNameChecking
$a=@(Get-YdbCheckArguments -Source $Source -Destination $Destination -Config '/dev/null' -ReportDirectory $Reports)
$i=[Array]::IndexOf($a,'--tpslimit');$a[$i+1]='0'
$code=Invoke-YdbLive -Executable $Rclone -Arguments $a
if ($code -ne 0) {throw "Check failed: $code"}
''', encoding='utf-8-sig')
        c = subprocess.run([str(PWSH), '-NoProfile', '-File', str(check_runner), '-Module', str(ROOT/'package/Backup.Core.psm1'), '-Rclone', str(RCLONE), '-Source', str(tmp/'source'), '-Destination', str(tmp/'destination'), '-Reports', str(tmp)], capture_output=True, text=True, encoding='utf-8', errors='strict', timeout=15)
        assert c.returncode == 0 and 'Проверка размеров' in c.stdout, c.stdout+c.stderr
        assert (tmp/'check-matched.txt').read_text(encoding='utf-8').splitlines() == ['файл [1].bin']
        print('PASS: real rate-limited rclone transfer, byte percent/speed/ETA/file counters/active Unicode file, checksum check')


def stalled_and_stale_log():
    with tempfile.TemporaryDirectory(prefix='ydb-stale-progress-') as tmp:
        tmp=Path(tmp)
        log=tmp/'copy.log'
        log.write_text('Transferred: 9 MiB / 9 MiB, 100%, 1 MiB/s, ETA 0s\nTransferred: 1 / 1, 100%\n * OLD-FILE: 100% /9MiB\n')
        child=tmp/'child.ps1'
        child.write_text("[Console]::Error.Write(('private signed URL' * 10000)); Start-Sleep -Seconds 4; exit 9", encoding='utf-8-sig')
        runner=tmp/'runner.ps1'
        runner.write_text('''param($Module,$Pwsh,$Child,$Log)
$ErrorActionPreference='Stop'
Import-Module $Module -Force -DisableNameChecking
$r=Invoke-YdbCapture -Executable $Pwsh -Arguments @('-NoProfile','-File',$Child) -ProgressLog $Log
if ($r.ExitCode -ne 9 -or $r.ErrorText.Length -ne 180000) {throw 'stderr drain/exit failure'}
''',encoding='utf-8-sig')
        r=subprocess.run([str(PWSH),'-NoProfile','-File',str(runner),'-Module',str(ROOT/'package/Backup.Core.psm1'),'-Pwsh',str(PWSH),'-Child',str(child),'-Log',str(log)],capture_output=True,text=True, encoding='utf-8', errors='strict',timeout=15)
        assert r.returncode==0,r.stdout+r.stderr
        assert 'OLD-FILE' not in r.stdout and '100%' not in r.stdout and 'private signed URL' not in r.stdout,r.stdout
        assert 'без нового прогресса 3 с.' in r.stdout,r.stdout
        print('PASS: stalled process shows increasing inactivity, stale prior-pass stats ignored, large stderr cannot deadlock or leak')


def current_snapshot():
    with tempfile.TemporaryDirectory(prefix='ydb-current-progress-') as tmp:
        tmp=Path(tmp)
        log=tmp/'copy.log'
        child=tmp/'child.ps1'
        child.write_text('''param($Log)
[IO.File]::WriteAllText($Log,"Transferred: 1 MiB / 2 MiB, 50%, 1 MiB/s, ETA 1s`nTransferred: 0 / 1, 0%`nTransferring:`n * FINISHED-FILE: 50% /2 MiB`n")
Start-Sleep -Seconds 2
[IO.File]::AppendAllText($Log,"Transferred: 2 MiB / 2 MiB, 100%, 1 MiB/s, ETA 0s`nTransferred: 1 / 1, 100%`nErrors: 1 (retrying may help)`nERROR: private signed URL`n")
Start-Sleep -Seconds 3
''',encoding='utf-8-sig')
        runner=tmp/'runner.ps1'
        runner.write_text('''param($Module,$Pwsh,$Child,$Log)
$ErrorActionPreference='Stop'
Import-Module $Module -Force -DisableNameChecking
$r=Invoke-YdbCapture -Executable $Pwsh -Arguments @('-NoProfile','-File',$Child,$Log) -ProgressLog $Log
if($r.ExitCode -ne 0){throw 'Fixture failed'}
''',encoding='utf-8-sig')
        r=subprocess.run([str(PWSH),'-NoProfile','-File',str(runner),'-Module',str(ROOT/'package/Backup.Core.psm1'),'-Pwsh',str(PWSH),'-Child',str(child),'-Log',str(log)],capture_output=True,text=True, encoding='utf-8', errors='strict',timeout=15)
        assert r.returncode==0,r.stdout+r.stderr
        updates=[line for line in r.stdout.splitlines() if 'Прошло' in line]
        assert any('FINISHED-FILE' in line for line in updates),updates
        assert 'FINISHED-FILE' not in updates[-1], ('Stale active filename', updates[-1])
        assert 'Ошибок: 1' in updates[-1],updates[-1]
        assert 'private signed URL' not in r.stdout,r.stdout
        print('PASS: current stats replace old active file; numeric errors visible without raw URLs')


if __name__ == '__main__':
    heartbeat()
    transfer_progress()
    stalled_and_stale_log()
    current_snapshot()
