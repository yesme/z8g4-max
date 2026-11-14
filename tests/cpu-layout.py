import contextlib
import importlib.util
from pathlib import Path
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
    for count in (4, 6, 8):
        output = root / f"generated-{count}"
        args = [str(script), str(output), "--infer-per-socket", str(count)]
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
        assert len(idle) == 104 - 2 * count and len(build) == 104 - 4 * count
        assert {0, 52}.issubset(build)
        assert idle - build == reserved and set(range(104)) - idle == siblings
        assert workers == reserved - {26 - count, 52 - count}
        assert f"AllowedCPUs={layout.cpu_list(reserved)}" in (output / "z8infer.slice").read_text(encoding="utf-8")
        assert (output / "10-z8-cpu.conf").read_text(encoding="utf-8") == f"[Slice]\nAllowedCPUs={layout.cpu_list(idle)}\n"

    (cpus / "cpu52/topology/thread_siblings_list").write_text("1,52\n", encoding="utf-8")
    try:
        layout.read_cores(cpus)
    except ValueError:
        pass
    else:
        raise AssertionError("accepted inconsistent siblings")

print("CPU layout tests passed: dual-socket topology, CPU0 in housekeeping, and 4/6/8-core masks.")
