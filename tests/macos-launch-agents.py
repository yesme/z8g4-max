from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory


script = Path("z8-kit/buildbarn/macos-launch-agents.py")

with TemporaryDirectory() as directory:
    root = Path(directory).resolve()
    shutil.copy(script, root / script.name)
    binaries = root / "bin"
    binaries.mkdir()
    for name in ("bb_storage", "bb_worker", "bb_runner"):
        (binaries / name).touch()
    site = {"hostname": "test-mac", "xcode": "26.1", "caseInsensitive": False}
    for name in ("hot", "cold", "work", "developerDir"):
        path = root / name
        path.mkdir()
        site[name] = str(path)
    site["socket"] = str(root / "work/r.sock")
    config = root / "edge-site.json"
    output = root / "agents"
    command = [sys.executable, str(root / script.name), str(binaries), str(output)]
    env = {**os.environ, "HOME": str(root), "USERPROFILE": str(root)}

    for field in site:
        invalid = site.copy()
        del invalid[field]
        config.write_text(json.dumps(invalid), encoding="utf-8")
        result = subprocess.run(command, env=env, text=True, capture_output=True)
        assert result.returncode == 2 and field in result.stderr, result.stderr
        assert not output.exists()

    for value in ("false", 0):
        config.write_text(json.dumps({**site, "caseInsensitive": value}), encoding="utf-8")
        result = subprocess.run(command, env=env, text=True, capture_output=True)
        assert result.returncode == 2 and "caseInsensitive" in result.stderr, result.stderr

    config.write_text(json.dumps(site), encoding="utf-8")
    subprocess.run(command, env=env, check=True)
    assert len(list(output.glob("*.plist"))) == 4
    cache = plistlib.loads((output / "local.z8.farm.cache.plist").read_bytes())
    assert cache["ProgramArguments"][-2] == str(binaries / "bb_storage")

print("macOS LaunchAgents tests passed: valid plists and required field checks.")
