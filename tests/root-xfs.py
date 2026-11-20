import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


config = Path("z8-kit/host/root-storage.yaml.example").read_text()
format_action = config.split("- id: root-fs\n", 1)[1].split("\n      - ", 1)[0]
options = json.loads(re.search(r"extra_options: (\[.*\])", format_action)[1])
assert options == ["-d", "su=512k,sw=2,concurrency=104", "-m", "crc=1,reflink=1"]
print("P4618 installer format options passed.")

# Older CI images still check the installer's arguments; the Desktop release can exercise mkfs itself.
mkfs = shutil.which("mkfs.xfs")
if mkfs:
    version = subprocess.check_output([mkfs, "-V"], text=True)
    major, minor = map(int, re.search(r"version (\d+)\.(\d+)", version).groups())
    if (major, minor) >= (6, 18):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "p4618.img"
            for size in (6_400_000_000_000, 6_401_200_000_000):
                with image.open("wb") as disk:
                    disk.truncate(size)
                run = subprocess.run([mkfs, "-N", *options, str(image)], text=True,
                                     check=True, capture_output=True, env={**os.environ, "LC_ALL": "C"})
                count, blocks = map(int, re.search(r"agcount=(\d+), agsize=(\d+)", run.stdout).groups())
                assert count in (104, 105) and blocks % 256 == 128
                assert re.search(r"sunit=128\s+swidth=256", run.stdout) and "reflink=1" in run.stdout
                assert "Warning" not in run.stderr, run.stderr
        print("P4618 XFS geometry dry runs passed with xfsprogs", version.strip())
