#!/usr/bin/env python3
"""Check that the locally built scheduler image is pinned consistently and applies upstream's dependency patch."""

from pathlib import Path
import re

BASE = Path(__file__).resolve().parents[1] / "z8-kit/buildbarn"


def main():
    compose = (BASE / "compose.worker.yaml").read_text()
    tag = re.search(r"^    image: (z8/bb-scheduler:\S+)$", compose, re.M).group(1)
    commit = re.fullmatch(r"z8/bb-scheduler:([0-9a-f]{7})-command-platform", tag).group(1)
    assert "pull_policy: never" in compose and "dockerfile: Dockerfile.scheduler" in compose

    dockerfile = (BASE / "Dockerfile.scheduler").read_text()
    fetched = re.search(r"git fetch --depth=1 https://github.com/buildbarn/bb-remote-execution.git ([0-9a-f]{40}) ", dockerfile)
    assert fetched.group(1).startswith(commit)
    # Both locally built images use the same Go toolchain image.
    toolchain = re.search(r"^FROM (golang:\S+) AS build$", dockerfile, re.M).group(1)
    assert f"FROM {toolchain} AS build\n" in (BASE / "Dockerfile.storage").read_text()

    # The one Go module that upstream's Bazel build patches for a Linux binary is patched here too,
    # with the patch taken from the bb-storage module the pinned commit depends on.
    patch = "com_github_grpc_ecosystem_go_grpc_prometheus/client-metrics-prevent-handled-twice.diff"
    steps = [
        "test \"$(grep -c 'module_override(' MODULE.bazel)\" = 5",
        "module=github.com/grpc-ecosystem/go-grpc-prometheus",
        "patches=$(go list -m -f '{{.Dir}}' github.com/buildbarn/bb-storage)/patches",
        f'git apply -p0 "$patches/{patch}"',
        'go mod edit -replace "$module=/deps"',
        "git apply /tmp/scheduler-command-platform.patch",
        "go build -trimpath -o /bb_scheduler ./cmd/bb_scheduler",
        'go version -m /bb_scheduler | grep -q "=>.*/deps"',
    ]
    positions = [dockerfile.index(step) for step in steps]
    assert positions == sorted(positions), "Patches must be applied before the build and checked after it."
    # The guard lists every Go module patch of the pinned commit, so a new pin cannot change the set unnoticed.
    assert f'= "{patch} org_golang_x_lint/generic.diff org_golang_x_sys/o-search.diff ' in dockerfile
    print("Scheduler image tests passed.")


if __name__ == "__main__":
    main()
