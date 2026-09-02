#!/bin/bash
# Compiles the segmenter sources with a throwaway main() into a CLI and runs it.
# No camera, no window, no permissions — just the maths as text.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
swiftc -O -target "$(uname -m)-apple-macos14.0" \
    Sources/Frame.swift \
    Sources/Segment.swift \
    Sources/ConnectedComponents.swift \
    Sources/ThresholdSegmenter.swift \
    Sources/MotionSegmenter.swift \
    Sources/FaceSegmenter.swift \
    tools/segtest/main.swift \
    -o build/segtest

exec ./build/segtest "$@"
