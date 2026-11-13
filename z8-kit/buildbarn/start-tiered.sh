#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname -- "$0")"
bash ./z8-buildbarn-check
exec docker compose -p z8-tiered -f compose.tiered.yaml up -d
