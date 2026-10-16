"""Test dependencies: use PATH or explicit environment overrides, never private host paths."""
import os
import shutil
from pathlib import Path
PWSH = Path(os.environ.get('YDB_PWSH') or shutil.which('pwsh') or 'pwsh')
RCLONE = Path(os.environ.get('YDB_RCLONE') or shutil.which('rclone') or 'rclone')
