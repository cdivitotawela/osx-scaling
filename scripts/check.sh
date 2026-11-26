#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run ScaleCoreChecks
script -q /dev/null swift run --skip-build ScaleCoreChecks --terminal
python3 scripts/smoke.py
