#!/bin/bash
# Builds segcam.app with just the Command Line Tools — no Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"

APP="segcam.app"
BIN="$APP/Contents/MacOS/segcam"
# Ad-hoc by default. An ad-hoc signature changes identity whenever the binary changes, so
# macOS re-asks for camera access after a rebuild; point SIGN_IDENTITY at a self-signed
# certificate to keep the grant.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Syphon (BSD 2-clause, bangnoise/vade) is not on macOS by default. TouchDesigner and OBS
# both ship a build of it; copy whichever is present into our bundle so segcam can read a
# Syphon feed without depending on those apps staying installed.
SYPHON=""
for candidate in \
    /Applications/TouchDesigner.app/Contents/Frameworks/Syphon.framework \
    /Applications/OBS.app/Contents/Frameworks/Syphon.framework \
    /Library/Frameworks/Syphon.framework; do
    [ -d "$candidate" ] && SYPHON="$candidate" && break
done
if [ -z "$SYPHON" ]; then
    echo "error: Syphon.framework not found (install TouchDesigner or OBS, or drop it in /Library/Frameworks)" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Info.plist "$APP/Contents/Info.plist"
cp -R "$SYPHON" "$APP/Contents/Frameworks/"

swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos14.0" \
    -F "$APP/Contents/Frameworks" -framework Syphon \
    -import-objc-header Sources/Syphon-Bridging.h \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Frame.swift \
    Sources/Segment.swift \
    Sources/ConnectedComponents.swift \
    Sources/ThresholdSegmenter.swift \
    Sources/MotionSegmenter.swift \
    Sources/FaceSegmenter.swift \
    Sources/Camera.swift \
    Sources/SyphonSource.swift \
    Sources/SegmentEngine.swift \
    Sources/PreviewView.swift \
    Sources/SegmentSwarm.swift \
    Sources/main.swift \
    -o "$BIN"

codesign --force --sign "$SIGN_IDENTITY" --identifier com.jamecoyne.segcam "$APP"

echo "built $PWD/$APP"
