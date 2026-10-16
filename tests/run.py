"""Offline regression suite. Does not open OAuth or access a user's cloud account."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from tool_paths import PWSH, RCLONE
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--report', type=Path, help='Optional local JSON report (do not publish logs)')
args = p.parse_args()
if not PWSH.is_file() or not RCLONE.is_file():
    sys.exit('Install PowerShell 7 and rclone on PATH, or set YDB_PWSH and YDB_RCLONE.')
env = dict(os.environ, YDB_PWSH=str(PWSH), YDB_RCLONE=str(RCLONE), PYTHONDONTWRITEBYTECODE='1')
rows = []
# RealYandexBackend.Tests is explicitly excluded: it makes an optional external negative API probe.
files = sorted(x for x in (ROOT / 'tests').iterdir() if x.name.endswith(('.Tests.ps1', '.Tests.py')) and x.name != 'RealYandexBackend.Tests.ps1')
for file in files:
    cmd = ([str(PWSH), '-NoLogo', '-NoProfile', '-NonInteractive', '-File', str(file)] if file.suffix == '.ps1' else [sys.executable, str(file)])
    run = subprocess.run(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace', timeout=300)
    row = {'test': file.name, 'exit_code': run.returncode}
    rows.append(row)
    print(('PASS' if run.returncode == 0 else 'FAIL') + ': ' + file.name, flush=True)
    if run.returncode:
        print(run.stdout[-10000:], flush=True)
summary = {'test_scripts': len(rows), 'passed': sum(r['exit_code'] == 0 for r in rows), 'failed': sum(r['exit_code'] != 0 for r in rows), 'results': rows}
print(json.dumps(summary, ensure_ascii=False, indent=2))
if args.report:
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
sys.exit(1 if summary['failed'] else 0)
