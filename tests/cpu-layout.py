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
        if count != 6:
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
        shared = layout.parse_cpu_list(values["Z8_BUILD_SHARED_CPUS"])
        workers = layout.parse_cpu_list(values["Z8_XOLOTL_POOL_CPUS"])
        reserved = set(range(26 - count, 26)) | set(range(52 - count, 52))
        siblings = {cpu + 52 for cpu in reserved}
        assert int(values["Z8_INFER_THREADS"]) == len(reserved)
        assert layout.parse_cpu_list(values["Z8_IRQ_BANNED_CPUS"]) == reserved | siblings
        assert idle == set(range(104)) and len(build) == 104 - 4 * count
        assert {0, 52}.issubset(build)
        assert idle - build == reserved | siblings
        # Builds may also use the inference threads' CPUs, never their HT siblings.
        assert shared == build | reserved and idle - shared == siblings
        slices = {name: (output / f"{name}.slice").read_text(encoding="utf-8")
                  for name in ("z8infer", "z8build", "z8build-local", "z8build-remote")}
        assert [slice.split("CPUWeight=")[1].split()[0] for slice in slices.values()] == ["200", "100", "200", "100"]
        assert "AllowedCPUs" not in slices["z8build"]
        assert workers == reserved - {26 - count, 52 - count}
        assert f"AllowedCPUs={layout.cpu_list(reserved)}" in (output / "z8infer.slice").read_text(encoding="utf-8")
        assert "MemoryLow=90G\n" in (output / "z8infer.slice").read_text(encoding="utf-8")
        assert (output / "10-z8-cpu.conf").read_text(encoding="utf-8") == f"[Slice]\nAllowedCPUs={layout.cpu_list(idle)}\n"


    # Exercise the same reserve/restore entry points used by the service.
    defaults = root / "generated-6/z8-infer-cpu.env"
    mode = root / "cpu-mode.sh"
    source = Path("z8-kit/host/cpu-mode.sh").read_text(encoding="utf-8")
    mode.write_text(source.replace("/etc/z8-infer-cpu.env", str(defaults)), encoding="utf-8")
    mock = root / "systemctl"
    mock.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n', encoding="utf-8")
    mock.chmod(0o755)
    with patch.dict("os.environ", PATH=f"{root}:{os.environ['PATH']}"):
        running = subprocess.check_output(["bash", str(mode), "reserve"], text=True)
        stopped = subprocess.check_output(["bash", str(mode), "restore"], text=True)
        # An environment file from before the shared set, or one edited to stop the sharing.
        legacy = root / "legacy-cpu-mode.sh"
        old_defaults = root / "legacy.env"
        old_defaults.write_text("".join(line for line in defaults.read_text().splitlines(keepends=True)
                                        if not line.startswith("Z8_BUILD_SHARED_CPUS=")), encoding="utf-8")
        legacy.write_text(source.replace("/etc/z8-infer-cpu.env", str(old_defaults)), encoding="utf-8")
        dedicated = subprocess.check_output(["bash", str(legacy), "reserve"], text=True)
    masks = dict(line.split("=", 1) for line in defaults.read_text().splitlines())
    order = ["system.slice", "user.slice", "machine.slice", "z8build.slice"]

    def applied(output, build_weight):
        lines = [line.split() for line in output.splitlines()]
        assert [line[:3] for line in lines] == [["set-property", "--runtime", slice] for slice in order]
        # Only the build slice changes its weight, in the same call that changes its CPUs.
        assert [line[4:] for line in lines] == [[]] * 3 + [[f"CPUWeight={build_weight}"]]
        return [line[3].removeprefix("AllowedCPUs=") for line in lines]

    unit_weight = (root / "generated-6/z8build.slice").read_text(encoding="utf-8").split("CPUWeight=")[1].split()[0]
    # Builds are an idle group only while they share the inference CPUs.
    assert applied(running, "idle") == [masks["Z8_BUILD_CPUS"]] * 3 + [masks["Z8_BUILD_SHARED_CPUS"]]
    assert applied(stopped, unit_weight) == [masks["Z8_IDLE_CPUS"]] * 4
    assert applied(dedicated, unit_weight) == [masks["Z8_BUILD_CPUS"]] * 4
    assert len(layout.parse_cpu_list(masks["Z8_BUILD_CPUS"])) == 80
    assert len(layout.parse_cpu_list(masks["Z8_BUILD_SHARED_CPUS"])) == 92
    assert len(layout.parse_cpu_list(masks["Z8_IDLE_CPUS"])) == 104

    (cpus / "cpu52/topology/thread_siblings_list").write_text("1,52\n", encoding="utf-8")
    try:
        layout.read_cores(cpus)
    except ValueError:
        pass
    else:
        raise AssertionError("accepted inconsistent siblings")

print("CPU layout tests passed: dual-socket topology, 2/4/6/8-core masks, the build group that is idle only while it shares, and 80/92/104 lifecycle restoration.")
