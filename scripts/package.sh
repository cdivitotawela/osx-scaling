#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

release_version=${1:-}
if [[ $# -ne 1 || ! "$release_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "Usage: scripts/package.sh vMAJOR.MINOR.PATCH[-prerelease]" >&2
  exit 1
fi
release_arch=$(uname -m)
case "$release_arch" in
  arm64|x86_64) ;;
  *) echo "Unsupported release architecture: $release_arch" >&2; exit 1 ;;
esac

./scripts/build.sh
lipo -verify_arch "$release_arch" bin/scalectl
codesign --verify --strict bin/scalectl
mkdir -p dist
release_stage=$(mktemp -d "$PWD/dist/.stage.XXXXXX")
trap 'rm -rf "$release_stage"' EXIT
mkdir -p "$release_stage/scalectl/bin"
cp bin/scalectl "$release_stage/scalectl/bin/scalectl"
cp README.md "$release_stage/scalectl/README.md"
release_archive="scalectl-${release_version}-macos-${release_arch}.tar.gz"
COPYFILE_DISABLE=1 tar -czf "dist/$release_archive" -C "$release_stage" scalectl
(
  cd dist
  shasum -a 256 "$release_archive" > "$release_archive.sha256"
  shasum -a 256 -c "$release_archive.sha256"
)
echo "Packaged dist/$release_archive"
