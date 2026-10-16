"""Real rclone + local HTTP fixture; never calls Yandex or uses real tokens."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json, subprocess, tempfile, threading, time
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
from tool_paths import PWSH, RCLONE
release = threading.Event()
gets = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, data, content_type='application/octet-stream'):
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Content-Type', content_type)
        self.send_header('Last-Modified', 'Mon, 01 Jan 2024 00:00:00 GMT')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def do_HEAD(self):
        self.send(b'good' if self.path.endswith('b-good.txt') else b'bad!')

    def do_GET(self):
        path = unquote(self.path)
        if path == '/':
            return self.send(b'<html><a href="a-stalled.txt">a-stalled.txt</a><a href="b-good.txt">b-good.txt</a></html>', 'text/html')
        gets.append((path, time.monotonic()))
        if path == '/a-stalled.txt':
            release.wait(15)
            return
        self.send(b'good')

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='ydb-stalled-') as temp:
        temp = Path(temp)
        config = temp / 'private.conf'
        config.write_text(f'[ydisk]\ntype = http\nurl = http://127.0.0.1:{server.server_port}/\n')
        script = temp / 'run.ps1'
        script.write_text('''param($Module, $Rclone, $Config, $Destination, $Result)
$ErrorActionPreference = 'Stop'
Import-Module $Module -Force -DisableNameChecking
$m = Get-Module Backup.Core
# Scale only time and rate for a fast repeatable timeout test. Retry policy is unchanged.
& $m {
    $script:OriginalNetworkArguments = (Get-Command Get-YdbNetworkArguments).ScriptBlock
    function script:Get-YdbNetworkArguments {
        param([switch]$ForCopy)
        $a = @(& $script:OriginalNetworkArguments -ForCopy:$ForCopy)
        foreach ($pair in @(@('--timeout','200ms'), @('--contimeout','1s'), @('--retries-sleep','0s'), @('--tpslimit','0'))) {
            $i = [Array]::IndexOf($a, $pair[0]); $a[$i+1] = $pair[1]
        }
        $a
    }
}
$b = New-YdbBinding -UserId '123' -Login 'synthetic-local-http' -Source 'ydisk:'
$r = Invoke-YdbBackup -Executable $Rclone -Config $Config -Binding $b -Destination $Destination
Write-YdbJson -Path $Result -Value $r
''')
        started = time.monotonic()
        run = subprocess.run([str(PWSH), '-NoLogo', '-NoProfile', '-File', str(script),
            '-Module', str(ROOT / 'package/Backup.Core.psm1'), '-Rclone', str(RCLONE),
            '-Config', str(config), '-Destination', str(temp / 'backup'), '-Result', str(temp / 'result.json')],
            capture_output=True, text=True, encoding='utf-8', errors='strict', input='НЕТ\n', timeout=25)
        if run.returncode:
            raise RuntimeError(run.stdout[-3000:] + run.stderr[-3000:])
        result = json.loads((temp / 'result.json').read_text(encoding='utf-8'))
        bad = [t for path,t in gets if path == '/a-stalled.txt']
        good = [t for path,t in gets if path == '/b-good.txt']
        summary = {'bad_attempts':len(bad), 'good_downloads':len(good),
            'first_good_after_bad_seconds':round(good[0]-bad[0],3) if good and bad else None,
            'status':result['Status'],'verified':result['Verified'],'matched':result['MatchedFiles'],
            'copy_exit':result['CopyExitCode'],'check_exit':result['CheckExitCode']}
        print(json.dumps(summary, indent=2), flush=True)
        assert good and bad and good[0]-bad[0] < 1.0, 'A stalled file must not monopolize the only transfer slot through nested retries'
        assert len(bad) == 1, 'One pass only; NO must not trigger an automatic retry'
        assert (temp / 'backup/Files/b-good.txt').read_bytes() == b'good'
        assert not (temp / 'backup/Files/a-stalled.txt').exists()
        assert result['Status'] == 'incomplete' and result['Verified'] is False
        assert result['MatchedFiles'] == 1 and result['InventoryFiles'] == 2
        assert result['CopyExitCode'] != 0 and result['CheckExitCode'] != 0
        missing = Path(result['Reports']) / 'check-missing.txt'
        assert 'a-stalled.txt' in missing.read_text(encoding='utf-8'), 'Do not silently exclude the unavailable original'
        print('PASS: real stalled headers; healthy next file copied; unavailable file reported; no false full-copy success')
finally:
    release.set()
    server.shutdown()
    server.server_close()
