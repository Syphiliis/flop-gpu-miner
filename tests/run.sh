#!/usr/bin/env bash
# Runs the test bench (tests/test.sh) in a throwaway Ubuntu 24.04 container: only Docker is needed on this machine.
# Nothing touches a GPU, FLOP or a real miner: every outside tool is a fake (see tests/test.sh).
#   bash tests/run.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
docker run --rm -v "$root:/src:ro" ubuntu:24.04 bash /src/tests/test.sh /src/flop-miner
