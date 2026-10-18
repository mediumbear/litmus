#!/usr/bin/env bash
# Installs the Zig version this project builds with into tools/zig-<version>, with
# tools/zig linking to it. Checks the download against the SHA-256 published in
# ziglang.org's release index.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=0.17.0

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=aarch64-macos ;;
  Darwin-x86_64) platform=x86_64-macos ;;
  Linux-x86_64) platform=x86_64-linux ;;
  Linux-aarch64) platform=aarch64-linux ;;
  *) echo "No Zig download known for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

dir="tools/zig-$VERSION"
if [ ! -x "$dir/zig" ]; then
  mkdir -p tools
  read -r url sha < <(curl -fsSL https://ziglang.org/download/index.json |
    python3 -c "import json, sys; d = json.load(sys.stdin)['$VERSION']['$platform']; print(d['tarball'], d['shasum'])")
  tarball="tools/zig-$VERSION.tar.xz"
  curl -fsSL -o "$tarball" "$url"
  echo "$sha  $tarball" | shasum -a 256 -c
  mkdir -p "$dir"
  tar -xJf "$tarball" -C "$dir" --strip-components=1
  rm "$tarball"
fi
ln -sfn "zig-$VERSION" tools/zig
tools/zig/zig version
