#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

shellcheck -x z8-kit/*/*.sh z8-kit/storage/z8-storage z8-kit/buildbarn/z8-buildbarn-check tests/*.sh
bash tests/storage.sh
bash tests/partition-optane.sh
bash tests/buildbarn-layout.sh
bash tests/buildbarn-jsonnet.sh
bash tests/pmem.sh
bash tests/serve-llama.sh
python3 tests/cpu-layout.py
python3 -B tests/inference-probe.py
python3 -B tests/macos-launch-agents.py
python3 -B tests/run-step.py
python3 -B tests/recovery-backup.py
