import contextlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch


sys.dont_write_bytecode = True
script = Path("z8-kit/host/cpu-layout.py")
spec = importlib.util.spec_from_file_location("cpu_layout", script)
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    cpus = root / "cpu"
    cpus.mkdir()
    (cpus / "online").write_text("0-103\n", encoding="utf-8")
    for cpu in range(104):
        primary = cpu % 52
        topology = cpus / f"cpu{cpu}/topology"
        topology.mkdir(parents=True)
        (topology / "physical_package_id").write_text(f"{primary // 26}\n", encoding="utf-8")
        (topology / "thread_siblings_list").write_text(f"{primary},{primary + 52}\n", encoding="utf-8")

    cores = layout.read_cores(cpus)
    assert [len(cores[socket]) for socket in (0, 1)] == [26, 26]
    for count in (2, 4, 6, 8):
        output = root / f"generated-{count}"
        args = [str(script), str(output)]
        if count != 2:
            args += ["--infer-per-socket", str(count)]
        with (
            patch.object(layout, "read_cores", return_value=cores),
            patch.object(sys, "argv", args),
            contextlib.redirect_stdout(None),
        ):
            layout.main()
        values = dict(
            line.split("=") for line in (output / "z8-infer-cpu.env").read_text(encoding="utf-8").splitlines()
        )
        idle = layout.parse_cpu_list(values["Z8_IDLE_CPUS"])
        build = layout.parse_cpu_list(values["Z8_BUILD_CPUS"])
        workers = layout.parse_cpu_list(values["Z8_XOLOTL_POOL_CPUS"])
        reserved = set(range(26 - count, 26)) | set(range(52 - count, 52))
        siblings = {cpu + 52 for cpu in reserved}
        assert int(values["Z8_INFER_THREADS"]) == len(reserved)
        assert layout.parse_cpu_list(values["Z8_IRQ_BANNED_CPUS"]) == reserved | siblings
        assert idle == set(range(104)) and len(build) == 104 - 4 * count
        assert {0, 52}.issubset(build)
        assert idle - build == reserved | siblings
        assert workers == reserved - {26 - count, 52 - count}
        assert f"AllowedCPUs={layout.cpu_list(reserved)}" in (output / "z8infer.slice").read_text(encoding="utf-8")
        assert "MemoryLow=90G\n" in (output / "z8infer.slice").read_text(encoding="utf-8")
        assert (output / "10-z8-cpu.conf").read_text(encoding="utf-8") == f"[Slice]\nAllowedCPUs={layout.cpu_list(idle)}\n"


    # Exercise the same reserve/restore entry points used by the service.
    defaults = root / "generated-2/z8-infer-cpu.env"
    mode = root / "cpu-mode.sh"
    source = Path("z8-kit/host/cpu-mode.sh").read_text(encoding="utf-8")
    mode.write_text(source.replace("/etc/z8-infer-cpu.env", str(defaults)), encoding="utf-8")
    mock = root / "systemctl"
    mock.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n', encoding="utf-8")
    mock.chmod(0o755)
    with patch.dict("os.environ", PATH=f"{root}:{os.environ['PATH']}"):
        running = subprocess.check_output(["bash", str(mode), "reserve"], text=True)
        stopped = subprocess.check_output(["bash", str(mode), "restore"], text=True)
    masks = dict(line.split("=", 1) for line in defaults.read_text().splitlines())
    for state, key in ((running, "Z8_BUILD_CPUS"), (stopped, "Z8_IDLE_CPUS")):
        assert [line.rsplit("=", 1)[-1] for line in state.splitlines()] == [masks[key]] * 4
    assert len(layout.parse_cpu_list(masks["Z8_BUILD_CPUS"])) == 96
    assert len(layout.parse_cpu_list(masks["Z8_IDLE_CPUS"])) == 104

    (cpus / "cpu52/topology/thread_siblings_list").write_text("1,52\n", encoding="utf-8")
    try:
        layout.read_cores(cpus)
    except ValueError:
        pass
    else:
        raise AssertionError("accepted inconsistent siblings")

print("CPU layout tests passed: dual-socket topology, 2/4/6/8-core masks, and 96/104 lifecycle restoration.")
