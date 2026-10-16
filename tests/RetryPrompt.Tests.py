"""Actual rclone/HTTP and PowerShell, no Yandex credentials. Scaled waits only."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote
from collections import Counter
import json, subprocess, tempfile, threading, os, time

ROOT = Path(__file__).resolve().parents[1]
from tool_paths import PWSH, RCLONE
BAD = 'вложенная/a-stalled [1].txt'
GOOD = 'вложенная/b-good.txt'
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def send(self, data, content_type='application/octet-stream'):
        self.send_response(200)
        self.send_header('Content-Length',str(len(data)))
        self.send_header('Content-Type',content_type)
        self.send_header('Last-Modified','Mon, 01 Jan 2024 00:00:00 GMT')
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(data)
    def do_HEAD(self): self.send(b'data')
    def do_GET(self):
        path = unquote(self.path).lstrip('/')
        if not path: return self.send('<a href="вложенная/">folder</a>'.encode(),'text/html; charset=utf-8')
        if path == 'вложенная/': return self.send('<a href="a-stalled%20%5B1%5D.txt">a</a><a href="b-good.txt">b</a>'.encode(),'text/html; charset=utf-8')
        with self.server.lock:
            self.server.events.append((path,time.monotonic()))
            self.server.gets[path] += 1
            number = self.server.gets[path]
        if path == BAD and not self.server.available and not (self.server.recover and number > 1):
            self.server.release.wait(20)
            return
        self.send(b'data')

def run_case(name, answers, recover=False, expected_bad=1, expected_prompts=1, verified=False, scale=True, available=False):
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    server.gets=Counter(); server.lock=threading.Lock(); server.release=threading.Event(); server.recover=recover
    server.available=available;server.events=[]
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='ydb-prompt-') as t:
            t=Path(t)
            (t/'fixture.conf').write_text(f'[ydisk]\ntype = http\nurl = http://127.0.0.1:{server.server_port}/\n')
            script=t/'run.ps1'
            script.write_text('''param($Module,$Rclone,$Config,$Destination,$Result,$Answers)
$ErrorActionPreference='Stop'
Import-Module $Module -Force -DisableNameChecking
$m=Get-Module Backup.Core
& $m {
 param($a,$d)
 $script:Answers=@(ConvertFrom-Json -InputObject $a)
 $script:PromptCount=0
 $script:Destination=$d
 $script:OriginalNetworkArguments=(Get-Command Get-YdbNetworkArguments).ScriptBlock
 function script:Get-YdbNetworkArguments {
  param([switch]$ForCopy)
  $a=@(& $script:OriginalNetworkArguments -ForCopy:$ForCopy)
  foreach($pair in @(@('--timeout','200ms'),@('--contimeout','1s'),@('--retries-sleep','0s'),@('--tpslimit','0'))) {
   $i=[Array]::IndexOf($a,$pair[0]);$a[$i+1]=$pair[1]
  }
  $a
 }
 function script:Read-Host {
  param($Prompt)
  if ($Prompt -notmatch 'ДА/НЕТ') {throw 'Prompt must visibly offer ДА/НЕТ'}
  if (-not (Test-Path -LiteralPath (Join-Path $script:Destination 'Files/вложенная/b-good.txt'))) {throw 'Prompt occurred before accessible file copied'}
  if($script:PromptCount -ge $script:Answers.Count) {throw 'Unexpected or automatic retry prompt'}
  $v=$script:Answers[$script:PromptCount];$script:PromptCount++;$v
 }
} $Answers $Destination
$b=New-YdbBinding -UserId '123' -Login 'synthetic-http' -Source 'ydisk:'
$r=Invoke-YdbBackup -Executable $Rclone -Config $Config -Binding $b -Destination $Destination
$n=& $m {$script:PromptCount}
Write-YdbJson -Path $Result -Value @{Backup=$r;Prompts=$n}
''',encoding='utf-8-sig')
            if not scale:
                text=script.read_text(encoding='utf-8-sig')
                text=text.replace('$a[$i+1]=$pair[1]', "if ($pair[0] -eq '--tpslimit') {$a[$i+1]='0'}")
                script.write_text(text,encoding='utf-8-sig')
            r=subprocess.run([str(PWSH),'-NoProfile','-File',str(script),'-Module',str(ROOT/'package/Backup.Core.psm1'),'-Rclone',str(RCLONE),'-Config',str(t/'fixture.conf'),'-Destination',str(t/'backup'),'-Result',str(t/'result.json'),'-Answers',json.dumps(answers,ensure_ascii=False)],capture_output=True,text=True,encoding='utf-8',errors='strict',timeout=60)
            assert r.returncode==0,r.stdout[-2500:]+r.stderr[-2500:]
            result=json.loads((t/'result.json').read_text(encoding='utf-8')); b=result['Backup']
            assert result['Prompts']==expected_prompts,(name,'missing/extra prompt',result)
            assert server.gets[BAD]==expected_bad,(name,'bad attempts',dict(server.gets))
            assert server.gets[GOOD]==1,(name,'healthy file was re-downloaded',dict(server.gets))
            if not scale:
                times={p:t for p,t in server.events}
                delay=times[GOOD]-times[BAD]
                assert 14 <= delay < 19, ('production timeout did not advance in 15s',delay)
                print('Observed production wait seconds:',round(delay,3),flush=True)
            assert b['Verified'] is verified,(name,b)
            assert b['InventoryFiles']==2 and b['MatchedFiles']==(2 if verified else 1),(name,b)
            assert (t/'backup/Files'/GOOD).read_bytes()==b'data'
            assert (t/'backup/Files'/BAD).exists() is verified
            assert b['FailedFiles']==([] if verified else [BAD]),(name,b)
            if expected_bad>1:
                lists=list(Path(b['Reports']).glob('retry-*-files.txt'))
                assert lists and all(p.read_text(encoding='utf-8-sig').splitlines()==[BAD] for p in lists)
            print('PASS',name,json.dumps({'bad_gets':server.gets[BAD],'good_gets':server.gets[GOOD],'prompts':result['Prompts'],'verified':b['Verified']},ensure_ascii=False),flush=True)
    finally:
        server.release.set();server.shutdown();server.server_close()

if __name__=='__main__':
    run_case('NO stops without automatic retry',['НЕТ'])
    if not os.environ.get('YDB_ONLY_NO'):
        run_case('all available: no prompt',[],expected_prompts=0,verified=True,available=True)
        run_case('production 15-second timeout: NO stops',['НЕТ'],scale=False)
        run_case('YES retries missing only and recovers',['ДА'],True,2,1,True)
        run_case('persistent failure asks again; NO stops',['ДА','НЕТ'],False,2,2)
        run_case('invalid/empty answers do not retry',['','maybe','нет'],False,1,3)
