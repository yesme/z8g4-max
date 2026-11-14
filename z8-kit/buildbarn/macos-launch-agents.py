#!/usr/bin/env python3
"""Render a user's launchd jobs for the native Apple Silicon Buildbarn worker."""

import argparse
import json
from pathlib import Path
import plistlib
import shlex


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bin_dir", type=Path, help="directory containing the three Buildbarn binaries")
    parser.add_argument("output", type=Path, help="new directory for the generated plists")
    args = parser.parse_args()
    config = Path(__file__).resolve().parent
    binaries = args.bin_dir.resolve(strict=True)
    site = json.loads((config / "edge-site.json").read_text(encoding="utf-8"))
    work = Path(site["work"])
    socket = Path(site["socket"])
    if not work.is_absolute() or socket.parent != work:
        parser.error("work must be absolute and socket must be directly below it")
    if not site["xcode"] or not Path(site["developerDir"]).is_dir():
        parser.error("set xcode and an existing developerDir in edge-site.json")
    cold_shards = site.get("coldShards")
    if cold_shards is not None and (
        not isinstance(cold_shards, list) or len(cold_shards) != 4 or len(set(cold_shards)) != 4
    ):
        parser.error("coldShards must contain four distinct mount paths")
    cold_paths = [Path(path) for path in (cold_shards if cold_shards is not None else [site["cold"]])]
    for path in [Path(site["hot"]), work, *cold_paths]:
        if not path.is_absolute() or not path.is_dir():
            parser.error(f"mount the data volume and create {path} first")
    commands = {
        "tunnel": ["/usr/bin/ssh", "-NT", "-o", "BatchMode=yes", "z8-build"],
        "cache": [str(binaries / "bb_storage"), str(config / "edge-cache.jsonnet")],
        "worker": [str(binaries / "bb_worker"), str(config / "edge-worker.jsonnet")],
        "runner": [str(binaries / "bb_runner"), str(config / "edge-runner.jsonnet")],
    }
    for name in ("cache", "worker", "runner"):
        if not Path(commands[name][0]).is_file():
            parser.error(f"missing {commands[name][0]}")
        # Refuse to run against the system disk when an external volume is absent.
        directories = (
            [Path(site["hot"]) / "cs/persistent_state", *(path / "cs" for path in cold_paths)]
            if name == "cache"
            else [work / "build"]
        )
        guard = " && ".join(f"test -d {shlex.quote(str(directory))}" for directory in directories)
        guard += ' && exec "$@"'
        commands[name] = ["/bin/sh", "-ec", guard, name, *commands[name]]
    commands["runner"] = ["/bin/sh", "-ec", 'rm -f -- "$1"; shift; exec "$@"', "runner", str(socket), *commands["runner"]]
    logs = Path.home() / "Library/Logs/z8-buildbarn"
    logs.mkdir(parents=True, exist_ok=True)
    args.output.mkdir()
    for name, command in commands.items():
        label = f"local.z8.farm.{name}"
        with (args.output / f"{label}.plist").open("wb") as stream:
            plistlib.dump({
                "Label": label,
                "ProgramArguments": command,
                "RunAtLoad": True,
                "KeepAlive": True,
                "ThrottleInterval": 10,
                "WorkingDirectory": str(config),
                "StandardOutPath": str(logs / f"{name}.log"),
                "StandardErrorPath": str(logs / f"{name}.err"),
            }, stream)


if __name__ == "__main__":
    main()
