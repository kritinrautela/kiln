#!/bin/zsh
# Builds the engine with a test runner and checks every action on made-up sample files.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
if ! log=$(swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  Sources/Model.swift Sources/Engine.swift Tests/*.swift -o build/kiln-tests 2>&1); then
  echo "$log" | grep -E "error" -A3; echo "build failed"; exit 1
fi
dir="${1:-$(mktemp -d -t kiln-tests)}"
./build/kiln-tests "$dir"
