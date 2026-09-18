#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import sys
import tempfile

SOURCE = Path("installer/repair-v17.sh")
TARGETS = ["guest-exec.sh", "xstartup.sh", "open-chrome.sh", "launch.sh", "stop.sh"]

text = SOURCE.read_text(encoding="utf-8")
failed = False

for name in TARGETS:
    pattern = re.compile(
        rf'cat > "\$STATE_DIR/{re.escape(name)}" <<(?:(?:\'([^\']+)\')|([A-Za-z0-9_]+))\n(.*?)\n(?:\1|\2)\n',
        re.S,
    )
    match = pattern.search(text)
    if not match:
        print(f"ERROR: generated script block not found: {name}", file=sys.stderr)
        failed = True
        continue

    body = match.group(3)
    with tempfile.NamedTemporaryFile("w", suffix=f"-{name}", delete=False, encoding="utf-8") as f:
        f.write(body)
        temp_path = f.name

    result = subprocess.run(["bash", "-n", temp_path], text=True, capture_output=True)
    if result.returncode != 0:
        print(f"ERROR: generated {name} fails bash -n", file=sys.stderr)
        if result.stderr:
            print(result.stderr.rstrip(), file=sys.stderr)
        failed = True
    else:
        print(f"OK: {name}")

if failed:
    sys.exit(1)
