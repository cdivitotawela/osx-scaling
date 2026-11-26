#!/bin/bash
set -euo pipefail
release_version=${1:-}
if [[ $# -lt 1 || $# -gt 2 || ! "$release_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "Usage: scripts/package.sh vMAJOR.MINOR.PATCH[-prerelease] [source-directory]" >&2
  exit 1
fi
# Release recovery may use updated packaging tooling with an unchanged source tag.
release_source=${2:-"$(dirname "$0")/.."}
cd "$release_source"
release_arch=$(uname -m)
case "$release_arch" in
  arm64|x86_64) ;;
  *) echo "Unsupported release architecture: $release_arch" >&2; exit 1 ;;
esac

./scripts/build.sh
lipo bin/scalectl -verify_arch "$release_arch"
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
