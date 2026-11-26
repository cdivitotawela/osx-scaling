#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product scalectl
scale_binary_dir=$(swift build -c release --show-bin-path)
mkdir -p bin
cp "$scale_binary_dir/scalectl" bin/scalectl
codesign --force --sign - bin/scalectl
echo "Built bin/scalectl"
