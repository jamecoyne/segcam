#!/bin/bash
# Publishes a test Syphon feed (a moving white square) so segcam's Syphon input can be
# exercised without TouchDesigner running.
set -euo pipefail
cd "$(dirname "$0")/.."
SYPHON="segcam.app/Contents/Frameworks/Syphon.framework"
[ -d "$SYPHON" ] || { echo "build segcam first (./build.sh)" >&2; exit 1; }

mkdir -p build
swiftc -O -target "$(uname -m)-apple-macos14.0" \
    -F segcam.app/Contents/Frameworks -framework Syphon \
    -import-objc-header Sources/Syphon-Bridging.h \
    -Xlinker -rpath -Xlinker "$PWD/segcam.app/Contents/Frameworks" \
    tools/syphonpub/main.swift -o build/syphonpub

exec ./build/syphonpub "$@"
